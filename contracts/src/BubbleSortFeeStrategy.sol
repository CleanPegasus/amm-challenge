// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

/// @title Bubble Sort Fee Strategy
/// @notice Fee tiers self-organize using bubble sort logic. Tiers with high
///         toxic flow scores "bubble up" to higher fee values, while tiers
///         attracting retail flow settle to lower fees.
///         - Toxic detection: trade size > 1.5x volume EMA
///         - On toxic: jump up through tiers proportionally to excess
///         - On retail: drift down 1 tier per trade
///         - Every SORT_INTERVAL trades: one bubble sort pass reorders tiers
///           based on accumulated toxic flow scores
contract Strategy is AMMStrategyBase {
    uint256 public constant NUM_TIERS = 7;

    // Storage layout (18 of 32 slots used)
    // Slots 0-6:   Fee tier values
    // Slots 7-13:  Toxic flow scores per tier
    // Slot 14:     Active tier index
    // Slot 15:     Volume EMA
    // Slot 16:     Last timestamp
    // Slot 17:     Trade count
    uint256 private constant SLOT_TIERS = 0;
    uint256 private constant SLOT_SCORES = 7;
    uint256 private constant SLOT_ACTIVE = 14;
    uint256 private constant SLOT_VOL_EMA = 15;
    uint256 private constant SLOT_LAST_STEP = 16;
    uint256 private constant SLOT_TRADE_COUNT = 17;

    // EMA and detection parameters
    uint256 public constant ALPHA = WAD / 10;
    uint256 public constant THRESHOLD_NUM = 3;
    uint256 public constant THRESHOLD_DENOM = 2;

    // Bubble sort parameters
    uint256 public constant SORT_INTERVAL = 10;
    uint256 public constant SCORE_DECAY = WAD * 9 / 10; // 90% retention per sort pass

    // Base tier index (where retail drifts toward)
    uint256 public constant BASE_TIER = 2;

    function afterInitialize(uint256, uint256) external override returns (uint256, uint256) {
        // Initialize fee tiers (ascending)
        writeSlot(SLOT_TIERS + 0, 15 * BPS);
        writeSlot(SLOT_TIERS + 1, 20 * BPS);
        writeSlot(SLOT_TIERS + 2, 25 * BPS);
        writeSlot(SLOT_TIERS + 3, 35 * BPS);
        writeSlot(SLOT_TIERS + 4, 50 * BPS);
        writeSlot(SLOT_TIERS + 5, 70 * BPS);
        writeSlot(SLOT_TIERS + 6, 100 * BPS);

        // Start at base tier (25 bps — undercuts 30bps normalizer)
        writeSlot(SLOT_ACTIVE, BASE_TIER);

        return (25 * BPS, 25 * BPS);
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        uint256 size = trade.amountY;
        uint256 volEma = readSlot(SLOT_VOL_EMA);
        uint256 activeTier = readSlot(SLOT_ACTIVE);
        uint256 lastStep = readSlot(SLOT_LAST_STEP);
        uint256 tradeCount = readSlot(SLOT_TRADE_COUNT) + 1;

        // Update volume EMA
        if (volEma == 0) {
            volEma = size;
        } else {
            volEma = (ALPHA * size + (WAD - ALPHA) * volEma) / WAD;
        }

        // Time-based tier decay: drift toward base tier between trades
        if (trade.timestamp > lastStep && activeTier > BASE_TIER) {
            uint256 elapsed = trade.timestamp - lastStep;
            if (elapsed > activeTier - BASE_TIER) {
                activeTier = BASE_TIER;
            } else {
                activeTier = activeTier - elapsed;
            }
        }

        // Detect toxic flow
        uint256 threshold = volEma * THRESHOLD_NUM / THRESHOLD_DENOM;
        if (size > threshold && threshold > 0) {
            // Toxic: jump up proportionally to how much trade exceeds threshold
            uint256 excess = size - threshold;
            uint256 tierJump = 1 + (excess * (NUM_TIERS - 1)) / threshold;
            if (tierJump > NUM_TIERS - 1) tierJump = NUM_TIERS - 1;

            uint256 newTier = activeTier + tierJump;
            if (newTier >= NUM_TIERS) newTier = NUM_TIERS - 1;

            // Increase toxic score for the destination tier
            uint256 score = readSlot(SLOT_SCORES + newTier);
            writeSlot(SLOT_SCORES + newTier, score + WAD);

            activeTier = newTier;
        } else {
            // Retail: drift down by 1 toward base tier
            if (activeTier > BASE_TIER) {
                activeTier = activeTier - 1;
            } else if (activeTier > 0) {
                // Below base is fine — stay at lowest possible
                // Don't go below 0 but allow staying at lower tiers
            }

            // Decrease toxic score for current tier (it's handling retail)
            uint256 score = readSlot(SLOT_SCORES + activeTier);
            if (score > WAD / 3) {
                writeSlot(SLOT_SCORES + activeTier, score - WAD / 3);
            } else {
                writeSlot(SLOT_SCORES + activeTier, 0);
            }
        }

        // Periodic bubble sort pass: reorder tiers by toxic scores
        if (tradeCount % SORT_INTERVAL == 0) {
            for (uint256 i = 0; i < NUM_TIERS - 1; i++) {
                uint256 scoreI = readSlot(SLOT_SCORES + i);
                uint256 scoreJ = readSlot(SLOT_SCORES + i + 1);

                // If lower-fee tier has MORE toxic flow, swap it up
                if (scoreI > scoreJ) {
                    // Swap fee values
                    uint256 feeI = readSlot(SLOT_TIERS + i);
                    uint256 feeJ = readSlot(SLOT_TIERS + i + 1);
                    writeSlot(SLOT_TIERS + i, feeJ);
                    writeSlot(SLOT_TIERS + i + 1, feeI);

                    // Swap scores
                    writeSlot(SLOT_SCORES + i, scoreJ);
                    writeSlot(SLOT_SCORES + i + 1, scoreI);

                    // Track active tier through the swap
                    if (activeTier == i) {
                        activeTier = i + 1;
                    } else if (activeTier == i + 1) {
                        activeTier = i;
                    }
                }

                // Decay score for this tier
                uint256 s = readSlot(SLOT_SCORES + i);
                writeSlot(SLOT_SCORES + i, s * SCORE_DECAY / WAD);
            }
            // Decay last tier
            uint256 lastS = readSlot(SLOT_SCORES + NUM_TIERS - 1);
            writeSlot(SLOT_SCORES + NUM_TIERS - 1, lastS * SCORE_DECAY / WAD);
        }

        // Get fee from active tier
        uint256 fee = clampFee(readSlot(SLOT_TIERS + activeTier));

        // Persist state
        writeSlot(SLOT_VOL_EMA, volEma);
        writeSlot(SLOT_LAST_STEP, trade.timestamp);
        writeSlot(SLOT_ACTIVE, activeTier);
        writeSlot(SLOT_TRADE_COUNT, tradeCount);

        return (fee, fee);
    }

    function getName() external pure override returns (string memory) {
        return "BubbleSortFee";
    }
}
