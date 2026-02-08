// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

/// @title Low-Base Spike-and-Decay Strategy
/// @notice Same spike-decay mechanics but with a 25 bps base fee instead of 30.
///         Undercuts the normalizer (30 bps) during calm periods to attract
///         more retail volume, while spiking harder during arb detection
///         with SPIKE_ADD=30bps and MAX_SPIKE=55bps.
///
/// Slot layout:
///   0: vol_ema     - EMA of trade sizes (WAD)
///   1: lastStep    - timestamp of last afterSwap call
///   2: spikeFee    - current spike component (WAD fee units)
contract Strategy is AMMStrategyBase {
    uint256 public constant BASE_FEE = 25 * BPS;
    uint256 public constant SPIKE_ADD = 30 * BPS;
    uint256 public constant MAX_SPIKE = 55 * BPS;
    uint256 public constant ALPHA = WAD / 10;
    uint256 public constant DECAY_SPEED = WAD / 8;
    uint256 public constant ARB_MULT = 2;

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

        // Detect large trade (likely arb)
        if (size > ARB_MULT * volEma) {
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
        return "LowBaseSpikeDecay";
    }
}
