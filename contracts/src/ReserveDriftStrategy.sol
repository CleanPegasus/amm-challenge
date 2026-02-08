// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

/// @title Reserve-Drift Spike-and-Decay Strategy
/// @notice Detects arb by measuring how much the reserve ratio has drifted
///         from a smoothed baseline. Large reserve drift indicates price
///         movement and arb opportunity. Spikes fee proportionally to drift,
///         with hyperbolic decay.
///
/// Slot layout:
///   0: smoothedRatio  - EMA of reserve ratio Y/X (WAD)
///   1: lastStep       - timestamp of last afterSwap call
///   2: spikeFee       - current spike component (WAD fee units)
contract Strategy is AMMStrategyBase {
    uint256 public constant BASE_FEE = 30 * BPS;
    uint256 public constant SPIKE_ADD = 25 * BPS;
    uint256 public constant MAX_SPIKE = 50 * BPS;
    uint256 public constant RATIO_ALPHA = WAD / 20;
    uint256 public constant DECAY_SPEED = WAD / 8;
    uint256 public constant DRIFT_THRESHOLD = WAD / 50;

    uint256 private constant SLOT_SMOOTHED_RATIO = 0;
    uint256 private constant SLOT_LAST_STEP = 1;
    uint256 private constant SLOT_SPIKE_FEE = 2;

    function afterInitialize(uint256, uint256) external pure override returns (uint256, uint256) {
        return (BASE_FEE, BASE_FEE);
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        uint256 smoothedRatio = readSlot(SLOT_SMOOTHED_RATIO);
        uint256 lastStep = readSlot(SLOT_LAST_STEP);
        uint256 spikeFee = readSlot(SLOT_SPIKE_FEE);

        // Current reserve ratio Y/X in WAD
        uint256 currentRatio = wdiv(trade.reserveY, trade.reserveX);

        // Bootstrap or update smoothed ratio
        if (smoothedRatio == 0) {
            smoothedRatio = currentRatio;
        } else {
            // Compute drift before updating EMA
            uint256 drift = absDiff(currentRatio, smoothedRatio);

            // Decay existing spike
            if (spikeFee > 0 && trade.timestamp > lastStep) {
                uint256 elapsed = trade.timestamp - lastStep;
                spikeFee = spikeFee * WAD / (WAD + elapsed * DECAY_SPEED);
            }

            // Spike if drift exceeds threshold (relative to smoothed ratio)
            // drift / smoothedRatio > DRIFT_THRESHOLD / WAD
            if (drift * WAD > DRIFT_THRESHOLD * smoothedRatio) {
                spikeFee = spikeFee + SPIKE_ADD;
                if (spikeFee > MAX_SPIKE) spikeFee = MAX_SPIKE;
            }

            // Update EMA of ratio
            smoothedRatio = (RATIO_ALPHA * currentRatio + (WAD - RATIO_ALPHA) * smoothedRatio) / WAD;
        }

        uint256 fee = clampFee(BASE_FEE + spikeFee);

        writeSlot(SLOT_SMOOTHED_RATIO, smoothedRatio);
        writeSlot(SLOT_LAST_STEP, trade.timestamp);
        writeSlot(SLOT_SPIKE_FEE, spikeFee);

        return (fee, fee);
    }

    function getName() external pure override returns (string memory) {
        return "ReserveDrift";
    }
}
