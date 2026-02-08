// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

/// @title Bubble Sort Fee V2 — Instant retail recovery + self-organizing tiers
/// @notice Key improvements over V1:
///   - Retail trades immediately return to base fee (25 bps) — no slow drift
///   - Toxic trades jump to a higher tier proportionally to excess
///   - Bubble sort periodically reorders tier fee VALUES based on toxic scores,
///     so the strategy "learns" which fee levels attract arbs vs retail
///   - The spike fee is the difference between the jumped-to tier and base tier
contract Strategy is AMMStrategyBase {
    uint256 public constant NUM_TIERS = 7;

    // Storage layout
    uint256 private constant SLOT_TIERS = 0;       // slots 0-6: fee tier values
    uint256 private constant SLOT_SCORES = 7;       // slots 7-13: toxic scores
    uint256 private constant SLOT_VOL_EMA = 14;
    uint256 private constant SLOT_LAST_STEP = 15;
    uint256 private constant SLOT_TRADE_COUNT = 16;
    uint256 private constant SLOT_SPIKE_FEE = 17;   // decaying spike from last arb

    // Parameters
    uint256 public constant BASE_FEE = 25 * BPS;
    uint256 public constant ALPHA = WAD / 10;
    uint256 public constant THRESHOLD_NUM = 3;
    uint256 public constant THRESHOLD_DENOM = 2;
    uint256 public constant DECAY_SPEED = WAD / 10;
    uint256 public constant SORT_INTERVAL = 10;
    uint256 public constant SCORE_DECAY = WAD * 9 / 10;
    uint256 public constant MAX_SPIKE = 90 * BPS;

    function afterInitialize(uint256, uint256) external override returns (uint256, uint256) {
        // Initialize fee tiers (what you get charged at each tier level)
        writeSlot(SLOT_TIERS + 0, 0);           // tier 0: no spike
        writeSlot(SLOT_TIERS + 1, 10 * BPS);    // tier 1: +10 bps
        writeSlot(SLOT_TIERS + 2, 20 * BPS);    // tier 2: +20 bps
        writeSlot(SLOT_TIERS + 3, 35 * BPS);    // tier 3: +35 bps
        writeSlot(SLOT_TIERS + 4, 50 * BPS);    // tier 4: +50 bps
        writeSlot(SLOT_TIERS + 5, 70 * BPS);    // tier 5: +70 bps
        writeSlot(SLOT_TIERS + 6, 90 * BPS);    // tier 6: +90 bps

        return (BASE_FEE, BASE_FEE);
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        uint256 size = trade.amountY;
        uint256 volEma = readSlot(SLOT_VOL_EMA);
        uint256 lastStep = readSlot(SLOT_LAST_STEP);
        uint256 spikeFee = readSlot(SLOT_SPIKE_FEE);
        uint256 tradeCount = readSlot(SLOT_TRADE_COUNT) + 1;

        // Update volume EMA
        if (volEma == 0) {
            volEma = size;
        } else {
            volEma = (ALPHA * size + (WAD - ALPHA) * volEma) / WAD;
        }

        // Decay existing spike fee over time
        if (spikeFee > 0 && trade.timestamp > lastStep) {
            uint256 elapsed = trade.timestamp - lastStep;
            spikeFee = spikeFee * WAD / (WAD + elapsed * DECAY_SPEED);
        }

        // Detect toxic flow
        uint256 threshold = volEma * THRESHOLD_NUM / THRESHOLD_DENOM;
        if (size > threshold && threshold > 0) {
            // Toxic: determine which tier to jump to based on excess
            uint256 excess = size - threshold;
            uint256 tierIndex = 1 + (excess * (NUM_TIERS - 1)) / threshold;
            if (tierIndex >= NUM_TIERS) tierIndex = NUM_TIERS - 1;

            // Look up spike fee from the (bubble-sorted) tier array
            uint256 tierSpike = readSlot(SLOT_TIERS + tierIndex);
            if (tierSpike > spikeFee) {
                spikeFee = tierSpike;
            }
            if (spikeFee > MAX_SPIKE) spikeFee = MAX_SPIKE;

            // Increase toxic score for this tier
            uint256 score = readSlot(SLOT_SCORES + tierIndex);
            writeSlot(SLOT_SCORES + tierIndex, score + WAD);
        } else {
            // Retail: decrease toxic score for base tier
            uint256 score = readSlot(SLOT_SCORES + 0);
            if (score > WAD / 3) {
                writeSlot(SLOT_SCORES + 0, score - WAD / 3);
            } else {
                writeSlot(SLOT_SCORES + 0, 0);
            }
        }

        // Periodic bubble sort pass on tier values
        if (tradeCount % SORT_INTERVAL == 0) {
            for (uint256 i = 0; i < NUM_TIERS - 1; i++) {
                uint256 scoreI = readSlot(SLOT_SCORES + i);
                uint256 scoreJ = readSlot(SLOT_SCORES + i + 1);

                // If lower tier has MORE toxic flow, swap it to higher position
                if (scoreI > scoreJ) {
                    uint256 feeI = readSlot(SLOT_TIERS + i);
                    uint256 feeJ = readSlot(SLOT_TIERS + i + 1);
                    writeSlot(SLOT_TIERS + i, feeJ);
                    writeSlot(SLOT_TIERS + i + 1, feeI);
                    writeSlot(SLOT_SCORES + i, scoreJ);
                    writeSlot(SLOT_SCORES + i + 1, scoreI);
                }

                // Decay scores
                uint256 s = readSlot(SLOT_SCORES + i);
                writeSlot(SLOT_SCORES + i, s * SCORE_DECAY / WAD);
            }
            uint256 lastS = readSlot(SLOT_SCORES + NUM_TIERS - 1);
            writeSlot(SLOT_SCORES + NUM_TIERS - 1, lastS * SCORE_DECAY / WAD);
        }

        // Final fee: base + decaying spike
        uint256 fee = clampFee(BASE_FEE + spikeFee);

        writeSlot(SLOT_VOL_EMA, volEma);
        writeSlot(SLOT_LAST_STEP, trade.timestamp);
        writeSlot(SLOT_SPIKE_FEE, spikeFee);
        writeSlot(SLOT_TRADE_COUNT, tradeCount);

        return (fee, fee);
    }

    function getName() external pure override returns (string memory) {
        return "BubbleSortFeeV2";
    }
}
