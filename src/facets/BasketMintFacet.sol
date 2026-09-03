// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStaticsBasket} from "../interfaces/IStaticsBasket.sol";
import {IStaticsBasketCollateral} from "../interfaces/IStaticsBasketCollateral.sol";
import {IStaticsPositionModule} from "../interfaces/IStaticsPosition.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibBasketMint} from "../libraries/LibBasketMint.sol";
import {LibBasketRewards} from "../libraries/LibBasketRewards.sol";
import {LibCustody} from "../libraries/LibCustody.sol";
import {LibMorpho} from "../libraries/LibMorpho.sol";
import {LibPosition} from "../position/LibPosition.sol";

contract BasketMintFacet is ReentrancyGuard {
    error BasketNotFound(uint256 basketId);
    error InvalidReceiver();

    function mint(uint256 basketId, uint256 shares, address receiver, uint256[] calldata maxAmountsIn)
        external
        nonReentrant
        returns (uint256[] memory amountsIn)
    {
        return _mint(basketId, shares, receiver, maxAmountsIn);
    }

    function createAndMintBasketCollateral(
        uint256 basketId,
        uint256 shares,
        address receiver,
        uint256[] calldata maxAmountsIn
    ) external payable nonReentrant returns (uint256 positionId, uint256[] memory amountsIn) {
        if (receiver == address(0)) revert InvalidReceiver();
        positionId = IStaticsPositionModule(address(this)).createPositionForModule{value: msg.value}(
            receiver, LibPosition.BASKET_MODULE, bytes32(basketId)
        );
        amountsIn = _mint(basketId, shares, address(this), maxAmountsIn);
        LibBasket.Basket storage configured = _getBasket(LibBasket.basketStorage(), basketId);
        LibCustody.reserve(LibCustody.basketAccount(basketId), configured.token, shares);
        LibBasketRewards.increasePosition(positionId, basketId, configured, shares);
        emit IStaticsBasketCollateral.BasketCollateralDeposited(positionId, basketId, msg.sender, shares);
    }

    function mintBasketCollateral(uint256 positionId, uint256 basketId, uint256 shares, uint256[] calldata maxAmountsIn)
        external
        nonReentrant
        returns (uint256[] memory amountsIn)
    {
        LibPosition.enforceAuthorized(positionId, msg.sender);
        LibMorpho.syncIfInitialized(positionId, msg.sender);
        amountsIn = _mint(basketId, shares, address(this), maxAmountsIn);
        LibBasket.Basket storage configured = _getBasket(LibBasket.basketStorage(), basketId);
        LibCustody.reserve(LibCustody.basketAccount(basketId), configured.token, shares);
        LibBasketRewards.increasePosition(positionId, basketId, configured, shares);
        emit IStaticsBasketCollateral.BasketCollateralDeposited(positionId, basketId, msg.sender, shares);
    }

    function quoteMint(uint256 basketId, uint256 shares) external view returns (uint256[] memory amountsIn) {
        LibBasket.Basket storage configured = _getBasket(LibBasket.basketStorage(), basketId);
        amountsIn = LibBasketMint.quote(configured, shares, IERC20(configured.token).totalSupply());
    }

    function _mint(uint256 basketId, uint256 shares, address receiver, uint256[] calldata maxAmountsIn)
        private
        returns (uint256[] memory amountsIn)
    {
        uint256[] memory maximums = maxAmountsIn;
        return LibBasketMint.mintFromPayer(basketId, shares, msg.sender, receiver, maximums);
    }

    function _getBasket(LibBasket.BasketStorage storage bs, uint256 basketId)
        private
        view
        returns (LibBasket.Basket storage configured)
    {
        configured = bs.baskets[basketId];
        if (configured.token == address(0)) revert BasketNotFound(basketId);
    }
}
