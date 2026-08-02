// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

interface IDiamondCut {
    enum FacetCutAction {
        Add,
        Replace,
        Remove
    }

    struct FacetCut {
        address facetAddress;
        FacetCutAction action;
        bytes4[] functionSelectors;
    }

    event DiamondCut(FacetCut[] diamondCut, address init, bytes data);

    function diamondCut(FacetCut[] calldata diamondCut_, address init, bytes calldata data) external;
}
