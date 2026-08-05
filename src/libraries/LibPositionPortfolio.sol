// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

library LibPositionPortfolio {
    bytes32 internal constant STORAGE_POSITION = keccak256("statics.storage.position.portfolio.v1");

    struct UintIndex {
        uint256[] values;
        mapping(uint256 value => uint256 indexPlusOne) indexPlusOne;
    }

    struct AddressIndex {
        address[] values;
        mapping(address value => uint256 indexPlusOne) indexPlusOne;
    }

    struct PortfolioStorage {
        mapping(uint256 positionId => UintIndex index) baskets;
        mapping(uint256 positionId => UintIndex index) loans;
        mapping(uint256 positionId => UintIndex index) liquidityPositions;
        mapping(uint256 positionId => AddressIndex index) globalRewardAssets;
    }

    error PositionPortfolioIndexCorrupted(uint256 positionId, uint256 value);
    error PositionPortfolioAddressIndexCorrupted(uint256 positionId, address value);

    function portfolioStorage() internal pure returns (PortfolioStorage storage ps) {
        bytes32 slot = STORAGE_POSITION;
        assembly ("memory-safe") {
            ps.slot := slot
        }
    }

    function addBasket(uint256 positionId, uint256 basketId) internal {
        _add(portfolioStorage().baskets[positionId], basketId);
    }

    function removeBasket(uint256 positionId, uint256 basketId) internal {
        _remove(portfolioStorage().baskets[positionId], positionId, basketId);
    }

    function addLoan(uint256 positionId, uint256 loanId) internal {
        _add(portfolioStorage().loans[positionId], loanId);
    }

    function removeLoan(uint256 positionId, uint256 loanId) internal {
        _remove(portfolioStorage().loans[positionId], positionId, loanId);
    }

    function addLiquidityPosition(uint256 positionId, uint256 tokenId) internal {
        _add(portfolioStorage().liquidityPositions[positionId], tokenId);
    }

    function removeLiquidityPosition(uint256 positionId, uint256 tokenId) internal {
        _remove(portfolioStorage().liquidityPositions[positionId], positionId, tokenId);
    }

    function addGlobalRewardAsset(uint256 positionId, address asset) internal {
        AddressIndex storage index = portfolioStorage().globalRewardAssets[positionId];
        if (index.indexPlusOne[asset] != 0) return;
        index.values.push(asset);
        index.indexPlusOne[asset] = index.values.length;
    }

    function removeGlobalRewardAsset(uint256 positionId, address asset) internal {
        AddressIndex storage values = portfolioStorage().globalRewardAssets[positionId];
        uint256 indexPlusOne = values.indexPlusOne[asset];
        if (indexPlusOne == 0) return;
        uint256 index = indexPlusOne - 1;
        if (index >= values.values.length || values.values[index] != asset) {
            revert PositionPortfolioAddressIndexCorrupted(positionId, asset);
        }
        uint256 lastIndex = values.values.length - 1;
        if (index != lastIndex) {
            address moved = values.values[lastIndex];
            values.values[index] = moved;
            values.indexPlusOne[moved] = indexPlusOne;
        }
        values.values.pop();
        delete values.indexPlusOne[asset];
    }

    function _add(UintIndex storage index, uint256 value) private {
        if (index.indexPlusOne[value] != 0) return;
        index.values.push(value);
        index.indexPlusOne[value] = index.values.length;
    }

    function _remove(UintIndex storage values, uint256 positionId, uint256 value) private {
        uint256 indexPlusOne = values.indexPlusOne[value];
        if (indexPlusOne == 0) return;
        uint256 index = indexPlusOne - 1;
        if (index >= values.values.length || values.values[index] != value) {
            revert PositionPortfolioIndexCorrupted(positionId, value);
        }
        uint256 lastIndex = values.values.length - 1;
        if (index != lastIndex) {
            uint256 moved = values.values[lastIndex];
            values.values[index] = moved;
            values.indexPlusOne[moved] = indexPlusOne;
        }
        values.values.pop();
        delete values.indexPlusOne[value];
    }
}
