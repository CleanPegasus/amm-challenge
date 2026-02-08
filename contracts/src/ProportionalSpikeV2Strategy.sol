// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

/// @title Proportional Spike V2 — Low Base variant
/// @notice Same proportional spike logic but with 25bps base fee to
///         undercut normalizer during calm periods.
///
/// Slot layout:
///   0: vol_ema     - EMA of trade sizes (WAD)
///   1: lastStep    - timestamp of last afterSwap call
///   2: spikeFee    - current spike component (WAD fee units)
contract Strategy is AMMStrategyBase {
    uint256 public constant BASE_FEE = 25 * BPS;
    uint256 public constant SPIKE_SCALE = 25 * BPS;
    uint256 public constant MAX_SPIKE = 75 * BPS;
    uint256 public constant ALPHA = WAD / 10;
    uint256 public constant DECAY_SPEED = WAD / 10;
    uint256 public constant THRESHOLD_NUM = 3;
    uint256 public constant THRESHOLD_DENOM = 2;

    uint256 private constant SLOT_VOL_EMA = 0;
    uint256 private constant SLOT_LAST_STEP = 1;
    uint256 private constant SLOT_SPIKE_FEE = 2;

    function afterInitialize(uint256, uint256) external pure override returns (uint256, uint256) {
        return (BASE_FEE, BASE_FEE);
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        uint256 size = trade.amountY;
        uint256 volEma = readSlot(SLOT_VOL_EMA);
        uint256 lastStep = readSlot(SLOT_LAST_STEP);
        uint256 spikeFee = readSlot(SLOT_SPIKE_FEE);

        if (volEma == 0) {
            volEma = size;
        } else {
            volEma = (ALPHA * size + (WAD - ALPHA) * volEma) / WAD;
        }

        if (spikeFee > 0 && trade.timestamp > lastStep) {
            uint256 elapsed = trade.timestamp - lastStep;
            spikeFee = spikeFee * WAD / (WAD + elapsed * DECAY_SPEED);
        }

        uint256 threshold = volEma * THRESHOLD_NUM / THRESHOLD_DENOM;
        if (size > threshold && threshold > 0) {
            uint256 excess = size - threshold;
            uint256 add = SPIKE_SCALE * excess / threshold;
            if (add > MAX_SPIKE) add = MAX_SPIKE;
            spikeFee = spikeFee + add;
            if (spikeFee > MAX_SPIKE) spikeFee = MAX_SPIKE;
        }

        uint256 fee = clampFee(BASE_FEE + spikeFee);

        writeSlot(SLOT_VOL_EMA, volEma);
        writeSlot(SLOT_LAST_STEP, trade.timestamp);
        writeSlot(SLOT_SPIKE_FEE, spikeFee);

        return (fee, fee);
    }

    function getName() external pure override returns (string memory) {
        return "ProportionalSpikeV2";
    }
}
