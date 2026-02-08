// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

/// @title Volume TWAP Strategy (150-step window)
/// @notice Tracks a 150-step rolling volume TWAP using 15 bucketed slots
///         (each bucket covers 10 consecutive steps). If an incoming swap's
///         size exceeds the TWAP, spike the fee by 25 bps.
///
/// Slot layout:
///   0-14:  Bucketed circular buffer — total volume per 10-step epoch
///   15:    Last epoch index + 1 (0 = uninitialized)
///   16:    Last timestamp + 1   (0 = uninitialized)
///   17:    Cached sum of all 15 buckets
///   18:    Total steps observed (for warmup gating)
contract Strategy is AMMStrategyBase {
    uint256 public constant BASE_FEE = 30 * BPS;
    uint256 public constant SPIKE_ADD = 25 * BPS;
    uint256 public constant NUM_BUCKETS = 15;
    uint256 public constant STEPS_PER_BUCKET = 10;
    uint256 public constant WINDOW = 150; // NUM_BUCKETS * STEPS_PER_BUCKET

    // Metadata slot indices (after the 15-slot bucket buffer)
    uint256 private constant SLOT_LAST_EPOCH = 15; // stored as epoch + 1
    uint256 private constant SLOT_LAST_TS = 16;    // stored as timestamp + 1
    uint256 private constant SLOT_SUM = 17;
    uint256 private constant SLOT_STEPS = 18;

    function afterInitialize(uint256, uint256) external pure override returns (uint256, uint256) {
        return (BASE_FEE, BASE_FEE);
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        uint256 rawLastEpoch = readSlot(SLOT_LAST_EPOCH);
        uint256 rawLastTs = readSlot(SLOT_LAST_TS);
        uint256 sum = readSlot(SLOT_SUM);
        uint256 stepsSeen = readSlot(SLOT_STEPS);
        uint256 size = trade.amountY;

        uint256 currEpoch = trade.timestamp / STEPS_PER_BUCKET;

        // Track total steps elapsed (rawLastTs stores ts+1, so 0 = uninitialized)
        if (rawLastTs > 0) {
            uint256 actualLastTs = rawLastTs - 1;
            if (trade.timestamp > actualLastTs) {
                stepsSeen += trade.timestamp - actualLastTs;
            }
        }

        // Clear stale buckets when we enter new epoch(s)
        if (rawLastEpoch > 0) {
            uint256 actualLastEpoch = rawLastEpoch - 1;
            if (currEpoch > actualLastEpoch) {
                uint256 epochGap = currEpoch - actualLastEpoch;
                if (epochGap >= NUM_BUCKETS) {
                    // Gap exceeds full window — clear everything
                    for (uint256 i = 0; i < NUM_BUCKETS; i++) {
                        writeSlot(i, 0);
                    }
                    sum = 0;
                } else {
                    // Clear only the buckets we're rotating past
                    for (uint256 i = 1; i <= epochGap; i++) {
                        uint256 clearIdx = (actualLastEpoch + i) % NUM_BUCKETS;
                        uint256 old = readSlot(clearIdx);
                        sum = sum > old ? sum - old : 0;
                        writeSlot(clearIdx, 0);
                    }
                }
            }
        }

        // Compute TWAP from historical data *before* including current trade
        uint256 twap = sum / WINDOW;

        // Accumulate current trade volume into its epoch bucket
        uint256 bucketIdx = currEpoch % NUM_BUCKETS;
        uint256 cur = readSlot(bucketIdx);
        writeSlot(bucketIdx, cur + size);
        sum += size;

        // Spike fee if the incoming trade exceeds the historical TWAP
        uint256 fee = BASE_FEE;
        if (stepsSeen >= WINDOW && twap > 0 && size > twap) {
            fee = BASE_FEE + SPIKE_ADD;
        }

        writeSlot(SLOT_LAST_EPOCH, currEpoch + 1);
        writeSlot(SLOT_LAST_TS, trade.timestamp + 1);
        writeSlot(SLOT_SUM, sum);
        writeSlot(SLOT_STEPS, stepsSeen);

        return (fee, fee);
    }

    function getName() external pure override returns (string memory) {
        return "VolumeTWAP";
    }
}
