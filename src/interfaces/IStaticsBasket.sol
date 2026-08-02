// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

interface IStaticsBasket {
    enum BasketStatus {
        Active,
        Quarantined,
        ExitOnly
    }

    struct FeeTier {
        uint256 minActionShares;
        uint256 feeShares;
    }

    struct CreateBasketParams {
        string name;
        string symbol;
        address[] assets;
        uint256[] bundleAmounts;
        FeeTier[] mintFeeTiers;
        FeeTier[] redemptionFeeTiers;
        uint16 flashFeeBps;
        uint16 originationFeeBps;
        uint16 extensionFeeBps;
        uint16 ltvBps;
        uint16 recoveryPenaltyBps;
        uint40 loanDuration;
    }

    struct PoolLaunchParams {
        uint160 sqrtPriceAssetPerBasketX96;
        uint256 pairedAssetAmount;
    }

    struct BasketView {
        address token;
        address creator;
        BasketStatus status;
        address[] assets;
        uint256[] bundleAmounts;
        FeeTier[] mintFeeTiers;
        FeeTier[] redemptionFeeTiers;
        uint16 flashFeeBps;
        uint16 originationFeeBps;
        uint16 extensionFeeBps;
        uint16 ltvBps;
        uint16 recoveryPenaltyBps;
        uint40 loanDuration;
    }

    event BasketCreated(
        uint256 indexed basketId, address indexed token, address indexed creator, string name, string symbol
    );
    event BasketConfigured(
        uint256 indexed basketId,
        address[] assets,
        uint256[] bundleAmounts,
        uint16 flashFeeBps,
        uint16 originationFeeBps,
        uint16 extensionFeeBps,
        uint16 ltvBps,
        uint16 recoveryPenaltyBps,
        uint40 loanDuration
    );
    event BasketFeeTiersConfigured(
        uint256 indexed basketId, bool indexed mintAction, uint256[] minActionShares, uint256[] feeShares
    );
    event BasketMinted(uint256 indexed basketId, address indexed payer, address indexed receiver, uint256 shares);
    event BasketRedeemed(uint256 indexed basketId, address indexed owner, address indexed receiver, uint256 shares);
    event BasketLaunched(
        uint256 indexed basketId,
        address indexed token,
        address indexed creator,
        uint256 basketShares,
        uint256 poolCount
    );

    function createBasket(
        CreateBasketParams calldata params,
        PoolLaunchParams[] calldata pools,
        uint256[] calldata maxAmountsIn,
        uint256 launchDeadline
    ) external payable returns (uint256 basketId, address token);
    function mint(uint256 basketId, uint256 shares, address receiver, uint256[] calldata maxAmountsIn)
        external
        returns (uint256[] memory amountsIn);
    function redeem(uint256 basketId, uint256 shares, address receiver, uint256[] calldata minAmountsOut)
        external
        returns (uint256[] memory amountsOut);
    function quoteMint(uint256 basketId, uint256 shares) external view returns (uint256[] memory amountsIn);
    function quoteRedeem(uint256 basketId, uint256 shares) external view returns (uint256[] memory amountsOut);
    function basket(uint256 basketId) external view returns (BasketView memory);
    function basketStatus(uint256 basketId) external view returns (BasketStatus);
    function basketCount() external view returns (uint256);
    function basketIdOf(address token) external view returns (uint256 basketId, bool exists);
    function vaultBalance(uint256 basketId, address asset) external view returns (uint256);
    function feeSharesFor(uint256 basketId, bool mintAction, uint256 actionShares)
        external
        view
        returns (uint256 feeShares);
}
