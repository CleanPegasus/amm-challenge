// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

/// @title TWAP + Spike-Decay Strategy
/// @notice Uses a 150-step bucketed volume TWAP to detect abnormally large
///         trades, then applies a spike fee that decays hyperbolically.
///         Combines the principled threshold of TWAP with the sustained
///         protection of spike-and-decay.
///
/// Slot layout:
///   0-14:  Bucketed circular buffer — total volume per 10-step epoch
///   15:    Last epoch index + 1 (0 = uninitialized)
///   16:    Last timestamp + 1   (0 = uninitialized)
///   17:    Cached sum of all 15 buckets
///   18:    Total steps observed (for warmup gating)
///   19:    Current spike fee component (WAD, decays over time)
contract Strategy is AMMStrategyBase {
    uint256 public constant BASE_FEE = 30 * BPS;
    uint256 public constant SPIKE_ADD = 25 * BPS;
    uint256 public constant MAX_SPIKE = 50 * BPS;
    uint256 public constant DECAY_SPEED = WAD / 8; // half-life ~8 steps
    uint256 public constant NUM_BUCKETS = 15;
    uint256 public constant STEPS_PER_BUCKET = 10;
    uint256 public constant WINDOW = 150;

    // Metadata slot indices
    uint256 private constant SLOT_LAST_EPOCH = 15;
    uint256 private constant SLOT_LAST_TS = 16;
    uint256 private constant SLOT_SUM = 17;
    uint256 private constant SLOT_STEPS = 18;
    uint256 private constant SLOT_SPIKE_FEE = 19;

    function afterInitialize(uint256, uint256) external pure override returns (uint256, uint256) {
        return (BASE_FEE, BASE_FEE);
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        uint256 rawLastEpoch = readSlot(SLOT_LAST_EPOCH);
        uint256 rawLastTs = readSlot(SLOT_LAST_TS);
        uint256 sum = readSlot(SLOT_SUM);
        uint256 stepsSeen = readSlot(SLOT_STEPS);
        uint256 spikeFee = readSlot(SLOT_SPIKE_FEE);
        uint256 size = trade.amountY;

        uint256 currEpoch = trade.timestamp / STEPS_PER_BUCKET;

        // --- Elapsed time for spike decay ---
        uint256 elapsed = 0;
        if (rawLastTs > 0) {
            uint256 actualLastTs = rawLastTs - 1;
            if (trade.timestamp > actualLastTs) {
                elapsed = trade.timestamp - actualLastTs;
                stepsSeen += elapsed;
            }
        }

        // --- Advance TWAP buckets ---
        if (rawLastEpoch > 0) {
            uint256 actualLastEpoch = rawLastEpoch - 1;
            if (currEpoch > actualLastEpoch) {
                uint256 epochGap = currEpoch - actualLastEpoch;
                if (epochGap >= NUM_BUCKETS) {
                    for (uint256 i = 0; i < NUM_BUCKETS; i++) {
                        writeSlot(i, 0);
                    }
                    sum = 0;
                } else {
                    for (uint256 i = 1; i <= epochGap; i++) {
                        uint256 clearIdx = (actualLastEpoch + i) % NUM_BUCKETS;
                        uint256 old = readSlot(clearIdx);
                        sum = sum > old ? sum - old : 0;
                        writeSlot(clearIdx, 0);
                    }
                }
            }
        }

        // --- Compute TWAP before including current trade ---
        uint256 twap = sum / WINDOW;

        // --- Accumulate current trade into bucket ---
        uint256 bucketIdx = currEpoch % NUM_BUCKETS;
        uint256 cur = readSlot(bucketIdx);
        writeSlot(bucketIdx, cur + size);
        sum += size;

        // --- Decay existing spike ---
        if (spikeFee > 0 && elapsed > 0) {
            spikeFee = spikeFee * WAD / (WAD + elapsed * DECAY_SPEED);
        }

        // --- Spike if trade exceeds TWAP ---
        if (stepsSeen >= WINDOW && twap > 0 && size > twap) {
            spikeFee = spikeFee + SPIKE_ADD;
            if (spikeFee > MAX_SPIKE) {
                spikeFee = MAX_SPIKE;
            }
        }

        uint256 fee = clampFee(BASE_FEE + spikeFee);

        writeSlot(SLOT_LAST_EPOCH, currEpoch + 1);
        writeSlot(SLOT_LAST_TS, trade.timestamp + 1);
        writeSlot(SLOT_SUM, sum);
        writeSlot(SLOT_STEPS, stepsSeen);
        writeSlot(SLOT_SPIKE_FEE, spikeFee);

        return (fee, fee);
    }

    function getName() external pure override returns (string memory) {
        return "TWAPSpikeDecay";
    }
}
