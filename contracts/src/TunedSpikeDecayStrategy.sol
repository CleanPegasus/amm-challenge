// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

/// @title Tuned Spike-and-Decay Strategy
/// @notice Same core logic as SpikeDecay but with more aggressive parameters:
///         - Lower ARB_MULT (1.5x instead of 2x) catches more arb trades
///         - Slower decay (half-life ~12 steps) keeps fees elevated longer
///         - Higher SPIKE_ADD and MAX_SPIKE for stronger protection
///
/// Slot layout:
///   0: vol_ema     - EMA of trade sizes (WAD)
///   1: lastStep    - timestamp of last afterSwap call
///   2: spikeFee    - current spike component (WAD fee units)
contract Strategy is AMMStrategyBase {
    uint256 public constant BASE_FEE = 30 * BPS;
    uint256 public constant SPIKE_ADD = 30 * BPS;
    uint256 public constant MAX_SPIKE = 60 * BPS;
    uint256 public constant ALPHA = WAD / 10;
    uint256 public constant DECAY_SPEED = WAD / 12;
    uint256 public constant ARB_MULT_NUM = 3;
    uint256 public constant ARB_MULT_DENOM = 2;

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

        // Bootstrap EMA
        if (volEma == 0) {
            volEma = size;
        } else {
            volEma = (ALPHA * size + (WAD - ALPHA) * volEma) / WAD;
        }

        // Decay existing spike
        if (spikeFee > 0 && trade.timestamp > lastStep) {
            uint256 elapsed = trade.timestamp - lastStep;
            spikeFee = spikeFee * WAD / (WAD + elapsed * DECAY_SPEED);
        }

        // Detect large trade (1.5x EMA threshold)
        if (size * ARB_MULT_DENOM > ARB_MULT_NUM * volEma) {
            spikeFee = spikeFee + SPIKE_ADD;
            if (spikeFee > MAX_SPIKE) {
                spikeFee = MAX_SPIKE;
            }
        }

        uint256 fee = clampFee(BASE_FEE + spikeFee);

        writeSlot(SLOT_VOL_EMA, volEma);
        writeSlot(SLOT_LAST_STEP, trade.timestamp);
        writeSlot(SLOT_SPIKE_FEE, spikeFee);

        return (fee, fee);
    }

    function getName() external pure override returns (string memory) {
        return "TunedSpikeDecay";
    }
}
