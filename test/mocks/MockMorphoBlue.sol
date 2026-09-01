// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    IMorphoBlue,
    MorphoMarket,
    MorphoMarketId,
    MorphoMarketParams,
    MorphoPosition
} from "../../src/interfaces/IMorphoBlue.sol";

contract MockMorphoBlue is IMorphoBlue {
    using SafeERC20 for IERC20;

    mapping(address authorizer => mapping(address authorized => bool)) public override isAuthorized;
    mapping(bytes32 id => MorphoMarketParams params) private _params;
    mapping(bytes32 id => MorphoMarket market_) private _markets;
    mapping(bytes32 id => mapping(address user => MorphoPosition position_)) private _positions;

    function createMarket(MorphoMarketParams calldata params) external returns (bytes32 id) {
        id = keccak256(abi.encode(params));
        _params[id] = params;
        _markets[id].lastUpdate = uint128(block.timestamp == 0 ? 1 : block.timestamp);
    }

    function setAuthorization(address authorized, bool newIsAuthorized) external override {
        isAuthorized[msg.sender][authorized] = newIsAuthorized;
    }

    function supplyCollateral(MorphoMarketParams memory params, uint256 assets, address onBehalf, bytes memory)
        external
        override
    {
        bytes32 id = keccak256(abi.encode(params));
        IERC20(params.collateralToken).safeTransferFrom(msg.sender, address(this), assets);
        _positions[id][onBehalf].collateral += uint128(assets);
    }

    function withdrawCollateral(MorphoMarketParams memory params, uint256 assets, address onBehalf, address receiver)
        external
        override
    {
        _requireAuthorized(onBehalf);
        bytes32 id = keccak256(abi.encode(params));
        _positions[id][onBehalf].collateral -= uint128(assets);
        IERC20(params.collateralToken).safeTransfer(receiver, assets);
    }

    function borrow(MorphoMarketParams memory params, uint256 assets, uint256, address onBehalf, address receiver)
        external
        override
        returns (uint256 assetsBorrowed, uint256 sharesBorrowed)
    {
        _requireAuthorized(onBehalf);
        bytes32 id = keccak256(abi.encode(params));
        _positions[id][onBehalf].borrowShares += uint128(assets);
        IERC20(params.loanToken).safeTransfer(receiver, assets);
        return (assets, assets);
    }

    function repay(MorphoMarketParams memory params, uint256 assets, uint256 shares, address onBehalf, bytes memory)
        external
        override
        returns (uint256 assetsRepaid, uint256 sharesRepaid)
    {
        bytes32 id = keccak256(abi.encode(params));
        uint256 amount = assets == 0 ? shares : assets;
        IERC20(params.loanToken).safeTransferFrom(msg.sender, address(this), amount);
        _positions[id][onBehalf].borrowShares -= uint128(amount);
        return (amount, amount);
    }

    function liquidate(
        MorphoMarketParams memory params,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares,
        bytes memory
    ) external override returns (uint256 assetsSeized, uint256 assetsRepaid) {
        bytes32 id = keccak256(abi.encode(params));
        uint256 repayAmount = repaidShares == 0 ? seizedAssets : repaidShares;
        IERC20(params.loanToken).safeTransferFrom(msg.sender, address(this), repayAmount);
        _positions[id][borrower].borrowShares -= uint128(repayAmount);
        _positions[id][borrower].collateral -= uint128(seizedAssets);
        IERC20(params.collateralToken).safeTransfer(msg.sender, seizedAssets);
        return (seizedAssets, repayAmount);
    }

    function position(MorphoMarketId id, address user) external view override returns (MorphoPosition memory) {
        return _positions[MorphoMarketId.unwrap(id)][user];
    }

    function market(MorphoMarketId id) external view override returns (MorphoMarket memory) {
        return _markets[MorphoMarketId.unwrap(id)];
    }

    function idToMarketParams(MorphoMarketId id) external view override returns (MorphoMarketParams memory) {
        return _params[MorphoMarketId.unwrap(id)];
    }

    function _requireAuthorized(address authorizer) private view {
        require(msg.sender == authorizer || isAuthorized[authorizer][msg.sender], "NOT_AUTHORIZED");
    }
}
