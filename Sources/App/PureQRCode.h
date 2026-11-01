#ifndef PureQRCode_h
#define PureQRCode_h

#include <stdint.h>
#include <stdbool.h>
#include <string.h>

// Pure-CPU ISO/IEC 18004 QR Code Matrix Encoder (Versions 1..5, EC Level L, Byte Mode, up to 106 bytes)
// Zero CoreImage, zero Metal, zero GPU, zero heap allocations — 100% crash-proof on iOS platform-application!

static inline int PureQR_EncodeUTF8(const uint8_t *msg, int msgLen, uint8_t outModules[37][37]) {
    if (!msg || msgLen <= 0 || msgLen > 106) return 0;

    // Select smallest QR Version (1..5) at EC Level L (single RS block for all V1..V5!)
    // V1: total=26, data=19 (max 17B) | V2: 44,34 (32B) | V3: 70,55 (53B) | V4: 100,80 (78B) | V5: 134,108 (106B)
    static const int kTotalCodewords[6] = { 0, 26, 44, 70, 100, 134 };
    static const int kDataCodewords[6]  = { 0, 19, 34, 55,  80, 108 };
    static const int kAlignSecond[6]    = { 0,  0, 18, 22,  26,  30 };

    int ver = 1;
    while (ver <= 5 && (msgLen + 2) > kDataCodewords[ver]) {
        ver++;
    }
    if (ver > 5) return 0;

    const int totalCount = kTotalCodewords[ver];
    const int dataCount  = kDataCodewords[ver];
    const int ecCount    = totalCount - dataCount;
    const int dim        = ver * 4 + 17;

    // 1. Build GF(256) exp/log tables (primitive polynomial 0x11D)
    uint8_t gfExp[512];
    uint8_t gfLog[256];
    memset(gfLog, 0, sizeof(gfLog));
    for (int i = 0; i < 8; i++) gfExp[i] = (uint8_t)(1U << i);
    for (int i = 8; i < 256; i++) {
        gfExp[i] = gfExp[i - 4] ^ gfExp[i - 5] ^ gfExp[i - 6] ^ gfExp[i - 8];
    }
    for (int i = 0; i < 255; i++) {
        gfLog[gfExp[i]] = (uint8_t)i;
        gfExp[i + 255]  = gfExp[i];
    }
    gfExp[510] = gfExp[0];
    gfExp[511] = gfExp[1];

    // 2. Pack Byte-mode bitstream: [0100 (4b)] [msgLen (8b)] [bytes...] [0000 terminator] [0xEC, 0x11 pad]
    uint8_t codewords[134];
    memset(codewords, 0, sizeof(codewords));
    int bitPos = 0;

    #define QR_PUT_BITS(val, nbits) do { \
        for (int _b = (nbits) - 1; _b >= 0; _b--) { \
            if (((val) >> _b) & 1) { \
                codewords[bitPos >> 3] |= (uint8_t)(0x80U >> (bitPos & 7)); \
            } \
            bitPos++; \
        } \
    } while (0)

    QR_PUT_BITS(0x4, 4); // Mode 0100 = 8-bit Byte
    QR_PUT_BITS(msgLen, 8);
    for (int i = 0; i < msgLen; i++) {
        QR_PUT_BITS(msg[i], 8);
    }
    int maxBits = dataCount * 8;
    int termBits = (maxBits - bitPos < 4) ? (maxBits - bitPos) : 4;
    QR_PUT_BITS(0, termBits);
    while ((bitPos & 7) != 0) {
        QR_PUT_BITS(0, 1);
    }
    int padIdx = 0;
    while ((bitPos >> 3) < dataCount) {
        QR_PUT_BITS((padIdx & 1) ? 0x11 : 0xEC, 8);
        padIdx++;
    }
    #undef QR_PUT_BITS

    // 3. Compute Reed-Solomon generator polynomial of degree ecCount
    uint8_t gen[32];
    memset(gen, 0, sizeof(gen));
    gen[0] = 1;
    int genLen = 1;
    for (int i = 0; i < ecCount; i++) {
        uint8_t nextGen[32];
        memset(nextGen, 0, sizeof(nextGen));
        uint8_t root = gfExp[i];
        for (int j = 0; j < genLen; j++) {
            if (gen[j] != 0) {
                nextGen[j]     ^= gen[j];
                nextGen[j + 1] ^= gfExp[gfLog[gen[j]] + gfLog[root]];
            }
        }
        genLen++;
        memcpy(gen, nextGen, (size_t)genLen);
    }

    // Polynomial division to obtain ecCount remainder bytes
    uint8_t rem[32];
    memset(rem, 0, sizeof(rem));
    for (int i = 0; i < dataCount; i++) {
        uint8_t factor = codewords[i] ^ rem[0];
        memmove(&rem[0], &rem[1], (size_t)(ecCount - 1));
        rem[ecCount - 1] = 0;
        if (factor != 0) {
            uint8_t logF = gfLog[factor];
            for (int j = 0; j < ecCount; j++) {
                uint8_t gCoeff = gen[j + 1];
                if (gCoeff != 0) {
                    rem[j] ^= gfExp[gfLog[gCoeff] + logF];
                }
            }
        }
    }
    for (int i = 0; i < ecCount; i++) {
        codewords[dataCount + i] = rem[i];
    }

    // 4. Evaluate all 8 masks and pick lowest ISO penalty score
    int bestPenalty = 0x7FFFFFFF;

    for (int mask = 0; mask < 8; mask++) {
        int8_t grid[37][37]; // -1 = unset, 0 = light, 1 = dark
        memset(grid, -1, sizeof(grid));

        // Finder patterns (3 corners)
        const int finders[3][2] = { {0, 0}, {dim - 7, 0}, {0, dim - 7} };
        for (int f = 0; f < 3; f++) {
            int fr = finders[f][0], fc = finders[f][1];
            for (int r = -1; r <= 7; r++) {
                if (fr + r < 0 || fr + r >= dim) continue;
                for (int c = -1; c <= 7; c++) {
                    if (fc + c < 0 || fc + c >= dim) continue;
                    bool dark = ((0 <= r && r <= 6 && (c == 0 || c == 6)) ||
                                 (0 <= c && c <= 6 && (r == 0 || r == 6)) ||
                                 (2 <= r && r <= 4 && 2 <= c && c <= 4));
                    grid[fr + r][fc + c] = dark ? 1 : 0;
                }
            }
        }

        // Alignment patterns (V2..V5)
        if (ver >= 2) {
            int pos[2] = { 6, kAlignSecond[ver] };
            for (int i = 0; i < 2; i++) {
                for (int j = 0; j < 2; j++) {
                    int ar = pos[i], ac = pos[j];
                    if (grid[ar][ac] != -1) continue;
                    for (int r = -2; r <= 2; r++) {
                        for (int c = -2; c <= 2; c++) {
                            bool dark = (r == -2 || r == 2 || c == -2 || c == 2 || (r == 0 && c == 0));
                            grid[ar + r][ac + c] = dark ? 1 : 0;
                        }
                    }
                }
            }
        }

        // Timing patterns
        for (int i = 8; i < dim - 8; i++) {
            if (grid[i][6] == -1) grid[i][6] = (i % 2 == 0) ? 1 : 0;
            if (grid[6][i] == -1) grid[6][i] = (i % 2 == 0) ? 1 : 0;
        }

        // Format info (EC Level L = 01b = 1)
        int fmtData = (1 << 3) | mask;
        int d = fmtData << 10;
        const int G15 = (1 << 10) | (1 << 8) | (1 << 5) | (1 << 4) | (1 << 2) | (1 << 1) | 1;
        for (int b = 14; b >= 10; b--) {
            if ((d >> b) & 1) d ^= (G15 << (b - 10));
        }
        int fmtBits = ((fmtData << 10) | d) ^ 0x5412;

        for (int i = 0; i < 15; i++) {
            int8_t mod = (int8_t)((fmtBits >> i) & 1);
            // Vertical
            if (i < 6)      grid[i][8] = mod;
            else if (i < 8) grid[i + 1][8] = mod;
            else            grid[dim - 15 + i][8] = mod;
            // Horizontal
            if (i < 8)      grid[8][dim - i - 1] = mod;
            else if (i < 9) grid[8][15 - i] = mod;
            else            grid[8][15 - i - 1] = mod;
        }
        grid[dim - 8][8] = 1; // Dark module

        // Place data + EC bits in zigzag upward/downward 2-column strips
        int inc = -1;
        int row = dim - 1;
        int byteIdx = 0;
        int bitIdx = 7;

        for (int col = dim - 1; col > 0; col -= 2) {
            if (col == 6) col--;
            while (1) {
                for (int c = 0; c < 2; c++) {
                    int cc = col - c;
                    if (grid[row][cc] == -1) {
                        bool dark = false;
                        if (byteIdx < totalCount) {
                            dark = (((codewords[byteIdx] >> bitIdx) & 1) == 1);
                        }
                        bool inv = false;
                        switch (mask) {
                            case 0: inv = ((row + cc) % 2 == 0); break;
                            case 1: inv = (row % 2 == 0); break;
                            case 2: inv = (cc % 3 == 0); break;
                            case 3: inv = ((row + cc) % 3 == 0); break;
                            case 4: inv = (((row / 2) + (cc / 3)) % 2 == 0); break;
                            case 5: inv = (((row * cc) % 2) + ((row * cc) % 3) == 0); break;
                            case 6: inv = ((((row * cc) % 2) + ((row * cc) % 3)) % 2 == 0); break;
                            case 7: inv = ((((row * cc) % 3) + ((row + cc) % 2)) % 2 == 0); break;
                        }
                        if (inv) dark = !dark;
                        grid[row][cc] = dark ? 1 : 0;

                        bitIdx--;
                        if (bitIdx < 0) {
                            byteIdx++;
                            bitIdx = 7;
                        }
                    }
                }
                row += inc;
                if (row < 0 || row >= dim) {
                    row -= inc;
                    inc = -inc;
                    break;
                }
            }
        }

        // Quick penalty score (runs + 2x2 blocks)
        int penalty = 0;
        for (int r = 0; r < dim; r++) {
            int runLen = 1;
            for (int c = 1; c < dim; c++) {
                if (grid[r][c] == grid[r][c - 1]) {
                    runLen++;
                    if (runLen == 5) penalty += 3;
                    else if (runLen > 5) penalty += 1;
                } else {
                    runLen = 1;
                }
            }
        }
        for (int c = 0; c < dim; c++) {
            int runLen = 1;
            for (int r = 1; r < dim; r++) {
                if (grid[r][c] == grid[r - 1][c]) {
                    runLen++;
                    if (runLen == 5) penalty += 3;
                    else if (runLen > 5) penalty += 1;
                } else {
                    runLen = 1;
                }
            }
        }
        for (int r = 0; r < dim - 1; r++) {
            for (int c = 0; c < dim - 1; c++) {
                int s = grid[r][c] + grid[r + 1][c] + grid[r][c + 1] + grid[r + 1][c + 1];
                if (s == 0 || s == 4) penalty += 3;
            }
        }

        if (penalty < bestPenalty) {
            bestPenalty = penalty;
            for (int r = 0; r < dim; r++) {
                for (int c = 0; c < dim; c++) {
                    outModules[r][c] = (uint8_t)(grid[r][c] == 1 ? 1 : 0);
                }
            }
        }
    }

    return dim;
}

#endif /* PureQRCode_h */
