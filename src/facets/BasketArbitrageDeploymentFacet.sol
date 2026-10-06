// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LibBasketArbitrageSettlement} from "../libraries/LibBasketArbitrageSettlement.sol";
import {StaticsFlashArbitrageReceiver} from "../periphery/StaticsFlashArbitrageReceiver.sol";

/// @notice Typed deployment is separate from settlement to preserve no-IR runtime headroom.
contract BasketArbitrageDeploymentFacet is ReentrancyGuard {
    function deployBasketArbitrageReceiver() external nonReentrant returns (address receiver) {
        LibBasketArbitrageSettlement.ReceiverStorage storage rs = LibBasketArbitrageSettlement.receiverStorage();
        receiver = rs.receiver;
        if (receiver == address(0)) {
            receiver = address(new StaticsFlashArbitrageReceiver(address(this)));
            rs.receiver = receiver;
        }
    }
}
