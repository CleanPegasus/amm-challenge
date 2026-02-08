// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

/// @title Spike-and-Decay Strategy
/// @notice Detects large trades (likely arb), spikes fees to protect,
///         then exponentially decays back to a competitive baseline.
///
/// Slot layout:
///   0: vol_ema     - EMA of trade sizes (WAD), used as arb detection threshold
///   1: lastStep    - timestamp of last afterSwap call
///   2: spikeFee    - current spike component (WAD fee units), decays over time
contract Strategy is AMMStrategyBase {
    /// @notice Base fee charged during calm markets (30 bps = normalizer match)
    uint256 public constant BASE_FEE = 30 * BPS;

    /// @notice Fee added per detected arb spike (25 bps)
    uint256 public constant SPIKE_ADD = 25 * BPS;

    /// @notice Maximum spike component (50 bps, total max = 80 bps)
    uint256 public constant MAX_SPIKE = 50 * BPS;

    /// @notice EMA smoothing factor: 10% weight to new observation
    uint256 public constant ALPHA = WAD / 10;

    /// @notice Spike decay speed: half-life of ~8 steps
    /// spike_new = spike_old * WAD / (WAD + elapsed * DECAY_SPEED)
    uint256 public constant DECAY_SPEED = WAD / 8;

    /// @notice Arb detection multiplier: trigger spike when trade > ARB_MULT * vol_ema
    uint256 public constant ARB_MULT = 2;

    // Slot indices
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

        // Bootstrap EMA on first trade
        if (volEma == 0) {
            volEma = size;
        } else {
            volEma = (ALPHA * size + (WAD - ALPHA) * volEma) / WAD;
        }

        // Decay existing spike based on elapsed time
        if (spikeFee > 0 && trade.timestamp > lastStep) {
            uint256 elapsed = trade.timestamp - lastStep;
            spikeFee = spikeFee * WAD / (WAD + elapsed * DECAY_SPEED);
        }

        // Detect large trade (likely arb) -> compound spike
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
        return "SpikeDecay";
    }
}
