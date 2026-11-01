/**
 * vision.js — Adaptive Night-Vision, Close-Up Moire Killer & Tight Text-Island Engine for VinFast BSS Screens
 * Runs 100% client-side in Browser (<canvas> ImageData) and Node.js (Uint8Array/Buffer).
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) {
    module.exports = factory();
  } else {
    root.BSSVision = factory();
  }
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  function clamp(v, lo, hi) {
    return v < lo ? lo : v > hi ? hi : v;
  }

  /**
   * Green-weighted luminance maximizes contrast of grey/white LCD subpixels against dark-blue cabinet panels.
   */
  function extractCleanLuma(rgba, width, height) {
    const luma = new Float32Array(width * height);
    for (let i = 0, p = 0; i < luma.length; i++, p += 4) {
      luma[i] = 0.34 * rgba[p] + 0.54 * rgba[p + 1] + 0.12 * rgba[p + 2];
    }
    return luma;
  }

  function buildIntegralImages(buf, w, h) {
    const stride = w + 1;
    const sum = new Float64Array(stride * (h + 1));
    const sqSum = new Float64Array(stride * (h + 1));
    for (let y = 1; y <= h; y++) {
      let rSum = 0, rSq = 0;
      const srcRow = (y - 1) * w;
      const dstRow = y * stride;
      const prevRow = (y - 1) * stride;
      for (let x = 1; x <= w; x++) {
        const v = buf[srcRow + x - 1];
        rSum += v;
        rSq += v * v;
        sum[dstRow + x] = sum[prevRow + x] + rSum;
        sqSum[dstRow + x] = sqSum[prevRow + x] + rSq;
      }
    }
    return { sum, sqSum, stride, w, h };
  }

  function boxMean(integ, x, y, rx, ry) {
    const radY = (ry === undefined) ? rx : ry;
    const x1 = Math.max(0, x - rx);
    const y1 = Math.max(0, y - radY);
    const x2 = Math.min(integ.w, x + rx + 1);
    const y2 = Math.min(integ.h, y + radY + 1);
    const area = Math.max(1, (x2 - x1) * (y2 - y1));
    const st = integ.stride;
    const s = integ.sum[y2 * st + x2] - integ.sum[y1 * st + x2] - integ.sum[y2 * st + x1] + integ.sum[y1 * st + x1];
    return s / area;
  }

  /**
   * Automatically locates the tight horizontal island containing "ID: BSS-..." across ALL shooting styles:
   *  1) Live camera horizontal strip (width / height >= 2.6)
   *  2) Normal or 1-scrim / 2-scrim dead-touchscreen shots where cards/popup shelf appear above (portrait or landscape)
   *  3) Direct Close-Up Focus shots aimed straight at "ID: BSS-..." (no white cards in frame, rejects "MAN LIET" marker ink below)
   */
  function autoLocateBssIdRoi(rgba, width, height) {
    const luma = extractCleanLuma(rgba, width, height);
    const integ = buildIntegralImages(luma, width, height);

    // Case 0: Already a narrow horizontal strip from Live Camera Strip Viewfinder
    if (width / Math.max(1, height) >= 2.6) {
      return refineTightIslandInBand(
        luma, integ, width, height,
        Math.round(height * 0.04),
        Math.round(height * 0.96),
        Math.round(width * 0.02),
        Math.round(width * 0.98),
        180,
        'closeup-strip'
      );
    }

    // Measure row brightness percentiles across central [26%..74%] width to check if card shelf exists above
    const xLo = Math.floor(width * 0.26);
    const xHi = Math.ceil(width * 0.74);
    const stepX = Math.max(1, Math.floor((xHi - xLo) / 140));
    const p85 = new Float32Array(height);
    const p35 = new Float32Array(height);
    const rowBuf = [];

    for (let y = 2; y < height - 2; y++) {
      rowBuf.length = 0;
      const rOff = y * width;
      for (let x = xLo; x < xHi; x += stepX) {
        rowBuf.push(luma[rOff + x]);
      }
      rowBuf.sort(function (a, b) { return a - b; });
      p85[y] = rowBuf.length ? rowBuf[Math.floor(rowBuf.length * 0.85)] : 0;
      p35[y] = rowBuf.length ? rowBuf[Math.floor(rowBuf.length * 0.35)] : 0;
    }

    const p85Sm = new Float32Array(height);
    for (let y = 3; y < height - 3; y++) {
      p85Sm[y] = (p85[y - 2] + p85[y - 1] + p85[y] + p85[y + 1] + p85[y + 2]) * 0.2;
    }

    // Stage 1: Detect steepest bright->dark cliff where cards / modal end and dark LCD footer begins
    const upWin = Math.max(8, Math.round(height * 0.038));
    const dnWin = Math.max(8, Math.round(height * 0.024));
    let bestDropY = -1;

    let y = Math.round(height * 0.16);
    const yEnd = Math.round(height * 0.88) - dnWin;
    while (y < yEnd) {
      let upSum = 0, dnSum = 0;
      for (let k = 2; k <= upWin + 1; k++) upSum += p85Sm[Math.max(0, y - k)];
      for (let k = 2; k <= dnWin + 1; k++) dnSum += p85Sm[Math.min(height - 1, y + k)];
      const upAvg = upSum / upWin;
      const dnAvg = dnSum / dnWin;

      // Handles normal white cards (upAvg ~210), 1-scrim dimmed cards (upAvg ~106-135), and 2-scrim cards (upAvg ~85+)
      if (upAvg >= 80 && dnAvg <= 76 && (upAvg - dnAvg) >= 34) {
        let peakCliff = -1;
        let cliffY = y;
        const zEnd = Math.min(yEnd, y + upWin);
        for (let r = Math.max(4, y - 4); r <= zEnd; r++) {
          let u2 = 0, d2 = 0;
          for (let k = 2; k <= upWin + 1; k++) u2 += p85Sm[Math.max(0, r - k)];
          for (let k = 2; k <= dnWin + 1; k++) d2 += p85Sm[Math.min(height - 1, r + k)];
          if ((u2 / upWin) >= 78 && (d2 / dnWin) <= 78) {
            const cliff = p85Sm[r - 3] - p85Sm[Math.min(height - 1, r + 3)];
            if (cliff > peakCliff) {
              peakCliff = cliff;
              cliffY = r;
            }
          }
        }
        bestDropY = cliffY;
        y = zEnd + 1;
      } else {
        y++;
      }
    }

    // Case 1: Card shelf found above -> search the dark-blue LCD footer band strictly BELOW bestDropY + safety gap!
    if (bestDropY > 0) {
      // Step clear of the bright card bottom border (at least 6px or 0.9% height below cliff) so card edge never outscores dim text!
      const searchY0 = Math.min(height - 20, bestDropY + Math.max(6, Math.round(height * 0.009)));
      const maxSearchH = Math.round(height * 0.13);
      let searchY1 = Math.min(height - 6, bestDropY + maxSearchH);

      // Stop before the LCD dark-blue footer drops into the physical black plastic bezel
      const probeY = Math.min(height - 6, searchY0 + Math.max(6, Math.round(height * 0.010)));
      const footerRefP85 = p85Sm[probeY];
      if (footerRefP85 > 13) {
        for (let ry = probeY + 8; ry < searchY1; ry++) {
          if (p85Sm[ry] < footerRefP85 * 0.72 && p35[ry] < footerRefP85 * 0.65) {
            searchY1 = Math.min(searchY1, ry + 3);
            break;
          }
        }
      }

      const cardBgCeiling = Math.max(68, footerRefP85 * 1.9 + 22);
      return refineTightIslandInBand(
        luma, integ, width, height,
        searchY0,
        Math.max(searchY0 + 16, searchY1),
        Math.round(width * 0.02),
        Math.round(width * 0.98),
        cardBgCeiling,
        'shelf-tight-island'
      );
    }

    // Case 2: Direct Close-Up Focus Shot on "ID: BSS-..." (no white card shelf in frame!)
    // Scan full width [3%..97%] and distinguish positive emissive LCD characters from dark marker ink ("MAN LIET") on painted metal!
    return locateDirectCloseUpFocusRoi(luma, integ, width, height);
  }

  /**
   * Finds the exact vertical center & tight horizontal text island inside a candidate [y0..y1, xMin..xMax] band.
   */
  function refineTightIslandInBand(luma, integ, width, height, y0, y1, xMin, xMax, bgCeiling, modeName) {
    const rxBg = Math.max(6, Math.round(width * 0.012));
    const ryBg = Math.max(4, Math.round(height * 0.008));
    const dxStep = Math.max(1, Math.round(width * 0.002));

    // Score each row by summing top-K positive emissive character-edge responses (ignores empty dark wings & bright card corners!)
    const rowScore = new Float32Array(height);
    const topK = 28;
    const hits = [];

    for (let y = Math.max(2, y0); y <= Math.min(height - 3, y1); y++) {
      hits.length = 0;
      const rOff = y * width;
      for (let x = Math.max(4, xMin); x <= Math.min(width - 5, xMax); x += dxStep) {
        const localBg = boxMean(integ, x, y, rxBg, ryBg);
        if (localBg > bgCeiling) continue; // mask out solid bright card shelf / glare
        const val = luma[rOff + x];
        const pos = val - localBg;
        if (pos > 2.0) {
          const hEdge = Math.abs(luma[rOff + x + dxStep] - luma[rOff + x - dxStep]);
          hits.push(pos + 0.45 * hEdge);
        }
      }
      if (hits.length >= 6) {
        hits.sort(function (a, b) { return b - a; });
        let s = 0;
        const lim = Math.min(topK, hits.length);
        for (let k = 0; k < lim; k++) s += hits[k];
        rowScore[y] = s / lim;
      }
    }

    // Subtract median sensor-grain floor from rowScore so dark background noise never bloats band height!
    const validRowScores = [];
    for (let y = Math.max(2, y0); y <= Math.min(height - 3, y1); y++) {
      validRowScores.push(rowScore[y]);
    }
    validRowScores.sort(function (a, b) { return a - b; });
    const rowNoiseFloor = validRowScores.length ? validRowScores[Math.floor(validRowScores.length * 0.45)] : 0;
    for (let y = Math.max(2, y0); y <= Math.min(height - 3, y1); y++) {
      rowScore[y] = Math.max(0, rowScore[y] - rowNoiseFloor);
    }

    // Find peak text line center row
    const winY = clamp(Math.round((y1 - y0) * 0.10), 2, 12);
    let bestRow = Math.round((y0 + y1) * 0.5);
    let bestS = -1;
    for (let y = Math.max(2, y0); y <= Math.min(height - 3, y1); y++) {
      let s = 0;
      for (let dy = -winY; dy <= winY; dy++) {
        const yy = clamp(y + dy, 0, height - 1);
        s += rowScore[yy];
      }
      if (s > bestS) {
        bestS = s;
        bestRow = y;
      }
    }

    // Measure natural vertical thickness of the text band around bestRow above noise floor
    const peakRowVal = Math.max(0.01, rowScore[bestRow]);
    let bandTop = bestRow;
    let bandBot = bestRow;
    const maxExpandY = (modeName === 'shelf-tight-island')
      ? Math.max(8, Math.round(height * 0.025))
      : Math.max(12, Math.round(height * 0.09));
    while (bandTop > y0 && rowScore[bandTop - 1] >= peakRowVal * 0.25 && (bestRow - bandTop) < maxExpandY) bandTop--;
    while (bandBot < y1 && rowScore[bandBot + 1] >= peakRowVal * 0.25 && (bandBot - bestRow) < maxExpandY) bandBot++;

    const rawTextH = Math.max(6, bandBot - bandTop + 1);
    const padY = Math.max(7, Math.round(rawTextH * 0.85));
    const minValidY = (modeName === 'shelf-tight-island') ? Math.max(0, y0 - 2) : 0;
    const ry = clamp(bandTop - padY, minValidY, height - 14);
    const rh = clamp((bandBot + padY) - ry + 1, 16, height - ry);

    // Tight horizontal island around the 22-character "ID: BSS-..." cluster inside [ry..ry+rh]
    const colPeak = new Float32Array(width);
    for (let x = Math.max(3, xMin); x <= Math.min(width - 4, xMax); x++) {
      let maxP = 0;
      for (let y = ry + 1; y < ry + rh - 1; y++) {
        const localBg = boxMean(integ, x, y, rxBg, ryBg);
        if (localBg > bgCeiling) continue;
        const p = luma[y * width + x] - localBg;
        if (p > maxP) maxP = p;
      }
      colPeak[x] = maxP;
    }

    const winX = Math.max(6, Math.round(width * 0.012));
    const colSm = new Float32Array(width);
    const colSamples = [];
    for (let x = Math.max(winX, xMin); x <= Math.min(width - winX - 1, xMax); x++) {
      let s = 0;
      for (let dx = -winX; dx <= winX; dx++) s += colPeak[x + dx];
      const v = s / (2 * winX + 1);
      colSm[x] = v;
      colSamples.push(v);
    }
    colSamples.sort(function (a, b) { return a - b; });
    // Use 8th percentile across [2%..98%] so even when close-up text spans 85% of image width,
    // colNoiseFloor measures genuine dark background noise and NEVER subtracts away the digits!
    const colNoiseFloor = colSamples.length ? colSamples[Math.floor(colSamples.length * 0.08)] : 0;

    let maxCol = 0.01;
    for (let x = Math.max(winX, xMin); x <= Math.min(width - winX - 1, xMax); x++) {
      colSm[x] = Math.max(0, colSm[x] - colNoiseFloor);
      if (colSm[x] > maxCol) maxCol = colSm[x];
    }

    // Locate horizontal center using a word-scale window (~15% width) so tiny corner glare specks never beat a 22-char ID line!
    const wordHalf = Math.max(18, Math.round(width * 0.08));
    let bestWordSum = -1;
    let centerCol = Math.round((xMin + xMax) * 0.5);
    for (let x = Math.max(wordHalf, xMin); x <= Math.min(width - wordHalf - 1, xMax); x++) {
      let ws = 0;
      for (let dx = -wordHalf; dx <= wordHalf; dx += 2) ws += colSm[x + dx];
      if (ws > bestWordSum) {
        bestWordSum = ws;
        centerCol = x;
      }
    }
    // Measure 85th-percentile stroke strength around word center (not single max pixel) so thinner digits aren't dwarfed by bold 'BSS'!
    const wordVals = [];
    for (let dx = -wordHalf; dx <= wordHalf; dx++) {
      const xx = clamp(centerCol + dx, 0, width - 1);
      if (colSm[xx] > 0) wordVals.push(colSm[xx]);
    }
    wordVals.sort(function (a, b) { return a - b; });
    const wordRef = wordVals.length ? wordVals[Math.floor(wordVals.length * 0.80)] : maxCol;

    const thr = Math.max(0.8, wordRef * 0.18);
    // Scale max horizontal bridge gap with BOTH character height (rawTextH * 2.8) and frame width!
    const maxGap = Math.max(14, Math.round(rawTextH * 2.8), Math.round(width * 0.045));
    let ix0 = centerCol, gap = 0;
    for (let x = centerCol; x >= xMin; x--) {
      if (colSm[x] >= thr) { ix0 = x; gap = 0; }
      else { gap++; if (gap > maxGap) break; }
    }
    let ix1 = centerCol; gap = 0;
    for (let x = centerCol; x <= xMax; x++) {
      if (colSm[x] >= thr) { ix1 = x; gap = 0; }
      else { gap++; if (gap > maxGap) break; }
    }

    const padX = Math.max(14, Math.round(rawTextH * 1.1), Math.round((ix1 - ix0 + 1) * 0.06));
    ix0 = clamp(ix0 - padX, 0, width - 20);
    ix1 = clamp(ix1 + padX, ix0 + 20, width - 1);

    // Safety fallback if image has virtually zero contrast before manual slider boost
    if (ix1 - ix0 < Math.round(width * 0.10)) {
      ix0 = xMin;
      ix1 = xMax;
    }

    return {
      x: ix0,
      y: ry,
      w: ix1 - ix0 + 1,
      h: rh,
      mode: modeName
    };
  }

  /**
   * Dedicated Close-Up Focus Locator when the user aims closely at "ID: BSS-..." without white cards above.
   * Rejects dark marker handwriting ("MAN LIET KO BAM") on blue painted metal below the screen bezel!
   */
  function locateDirectCloseUpFocusRoi(luma, integ, width, height) {
    const xMin = Math.round(width * 0.03);
    const xMax = Math.round(width * 0.97);

    // Measure row median (rowP50):
    // - On LCD screen ("ID: BSS-..."), rowP50 is the dark screen background; characters rise ABOVE rowP50 (posEnergy >> negEnergy).
    // - On painted cabinet metal ("MAN LIET KO BAM"), rowP50 is bright blue paint; dark marker ink plunges BELOW rowP50 (negEnergy >> posEnergy)!
    const rowP50 = new Float32Array(height);
    const tmp = [];
    const stepX = Math.max(1, Math.floor((xMax - xMin) / 140));
    for (let y = 2; y < height - 2; y++) {
      tmp.length = 0;
      for (let x = xMin; x < xMax; x += stepX) tmp.push(luma[y * width + x]);
      tmp.sort(function (a, b) { return a - b; });
      rowP50[y] = tmp[Math.floor(tmp.length * 0.5)] || 0;
    }

    const rowLineScore = new Float32Array(height);
    for (let y = Math.round(height * 0.03); y < Math.round(height * 0.95); y++) {
      const med = rowP50[y];
      if (med > 115) continue; // painted cabinet in daylight / bright modal card
      let posEnergy = 0;
      let negEnergy = 0;
      let posPeaks = 0;
      let inPos = false;
      const rOff = y * width;

      for (let x = xMin; x <= xMax; x += stepX) {
        const diff = luma[rOff + x] - med;
        if (diff > 4.0) {
          posEnergy += diff;
          if (!inPos) { posPeaks++; inPos = true; }
        } else {
          inPos = false;
          if (diff < -6.0) negEnergy += (-diff);
        }
      }

      if (posEnergy > negEnergy * 1.35 && posPeaks >= 5) {
        rowLineScore[y] = posEnergy * (1.0 + Math.min(28, posPeaks) * 0.10);
      }
    }

    const bandWin = clamp(Math.round(height * 0.035), 4, 22);
    let peakY = Math.round(height * 0.45);
    let bestScore = -1;
    for (let y = Math.round(height * 0.04); y < Math.round(height * 0.94); y++) {
      let sc = 0;
      for (let dy = -bandWin; dy <= bandWin; dy++) {
        const yy = clamp(y + dy, 0, height - 1);
        sc += rowLineScore[yy];
      }
      if (sc > bestScore) {
        bestScore = sc;
        peakY = y;
      }
    }

    const searchHalf = clamp(Math.round(height * 0.12), 16, Math.round(height * 0.22));
    const sy0 = clamp(peakY - searchHalf, 2, height - 20);
    const sy1 = clamp(peakY + searchHalf, sy0 + 16, height - 3);
    const autoExposedBgCeil = Math.max(95, rowP50[peakY] * 1.75 + 28);

    return refineTightIslandInBand(
      luma, integ, width, height,
      sy0, sy1, xMin, xMax,
      autoExposedBgCeil,
      'closeup-focus-island'
    );
  }

  /**
   * Estimates text baseline slope in degrees (-5.5 .. +5.5) using horizontal character-stroke gradients.
   */
  function estimateTextTiltDeg(hpSignal, w, h) {
    const hGrad = new Float32Array(w * h);
    for (let y = 2; y < h - 2; y++) {
      const r = y * w;
      for (let x = 3; x < w - 3; x++) {
        hGrad[r + x] = Math.abs(hpSignal[r + x + 1] - hpSignal[r + x - 1]);
      }
    }

    let bestAngle = 0.0;
    let bestVar = -1.0;
    const cx = w * 0.5;
    const proj = new Float32Array(h);
    const cnt = new Uint16Array(h);

    for (let deg = -5.5; deg <= 5.501; deg += 0.5) {
      const slope = Math.tan((deg * Math.PI) / 180.0);
      proj.fill(0);
      cnt.fill(0);

      for (let y = 2; y < h - 2; y++) {
        const r = y * w;
        for (let x = 4; x < w - 4; x++) {
          const ry = Math.round(y - (x - cx) * slope);
          if (ry >= 0 && ry < h) {
            proj[ry] += hGrad[r + x];
            cnt[ry]++;
          }
        }
      }

      let sum = 0, n = 0;
      for (let y = 0; y < h; y++) {
        if (cnt[y] > Math.max(8, Math.round(w * 0.15))) {
          proj[y] /= cnt[y];
          sum += proj[y];
          n++;
        } else {
          proj[y] = 0;
        }
      }
      if (n < 4) continue;
      const mean = sum / n;
      let variance = 0;
      for (let y = 0; y < h; y++) {
        if (proj[y] > 0) {
          const d = proj[y] - mean;
          variance += d * d;
        }
      }
      variance /= n;
      if (variance > bestVar) {
        bestVar = variance;
        bestAngle = deg;
      }
    }
    return bestAngle;
  }

  function cubicWeight(v0, v1, v2, v3, t) {
    const a = -0.68; // Crisp Catmull-Rom bicubic kernel separates adjacent digits while keeping inner loops open!
    const t2 = t * t;
    const t3 = t2 * t;
    return (
      v0 * (a * (t3 - 2 * t2 + t)) +
      v1 * ((a + 2) * t3 - (a + 3) * t2 + 1) +
      v2 * (-(a + 2) * t3 + (2 * a + 3) * t2 - a * t) +
      v3 * (-a * (t3 - t2))
    );
  }

  /**
   * Adaptive Resampler:
   * - When upscaling tiny wide-shot text (scale >= 1): Sharp Catmull-Rom Bicubic + background border fill (no vertical edge streaks!)
   * - When downscaling huge 12MP macro close-up text (scale < 1): Box-area anti-aliased pre-filter kills RGB LCD Moire grid!
   */
  function adaptiveDeskewAndResample(src, sw, sh, angleDeg, scaleX, scaleY, fillBgVal) {
    let workSrc = src;
    if (scaleX < 0.92 || scaleY < 0.92) {
      // Anti-aliasing pre-blur suppresses cabinet LCD RGB subpixel moire grid on close-up macro shots!
      const integ = buildIntegralImages(src, sw, sh);
      const rx = Math.max(1, Math.round(0.55 / Math.min(scaleX, scaleY)));
      const ry = Math.max(1, Math.round(0.55 / scaleY));
      workSrc = new Float32Array(sw * sh);
      for (let y = 0; y < sh; y++) {
        for (let x = 0; x < sw; x++) {
          workSrc[y * sw + x] = boxMean(integ, x, y, rx, ry);
        }
      }
    }

    const dw = Math.max(32, Math.round(sw * scaleX));
    const dh = Math.max(24, Math.round(sh * scaleY));
    const dst = new Float32Array(dw * dh);

    const rad = (angleDeg * Math.PI) / 180.0;
    const cosA = Math.cos(rad);
    const sinA = Math.sin(rad);
    const scx = (sw - 1) * 0.5;
    const scy = (sh - 1) * 0.5;
    const dcx = (dw - 1) * 0.5;
    const dcy = (dh - 1) * 0.5;

    function sampleSafe(x, y) {
      if (x < 0 || x >= sw || y < 0 || y >= sh) return fillBgVal;
      return workSrc[y * sw + x];
    }

    for (let dy = 0; dy < dh; dy++) {
      const uy = (dy - dcy) / scaleY;
      const dRow = dy * dw;
      for (let dx = 0; dx < dw; dx++) {
        const ux = (dx - dcx) / scaleX;
        const sx = scx + ux * cosA - uy * sinA;
        const sy = scy + ux * sinA + uy * cosA;

        if (sx < 0 || sx >= sw - 1 || sy < 0 || sy >= sh - 1) {
          dst[dRow + dx] = fillBgVal;
          continue;
        }

        const ix = Math.floor(sx);
        const iy = Math.floor(sy);
        const fx = sx - ix;
        const fy = sy - iy;

        const r0 = cubicWeight(sampleSafe(ix - 1, iy - 1), sampleSafe(ix, iy - 1), sampleSafe(ix + 1, iy - 1), sampleSafe(ix + 2, iy - 1), fx);
        const r1 = cubicWeight(sampleSafe(ix - 1, iy),     sampleSafe(ix, iy),     sampleSafe(ix + 1, iy),     sampleSafe(ix + 2, iy),     fx);
        const r2 = cubicWeight(sampleSafe(ix - 1, iy + 1), sampleSafe(ix, iy + 1), sampleSafe(ix + 1, iy + 1), sampleSafe(ix + 2, iy + 1), fx);
        const r3 = cubicWeight(sampleSafe(ix - 1, iy + 2), sampleSafe(ix, iy + 2), sampleSafe(ix + 1, iy + 2), sampleSafe(ix + 2, iy + 2), fx);
        dst[dRow + dx] = cubicWeight(r0, r1, r2, r3, fy);
      }
    }
    return { data: dst, width: dw, height: dh };
  }

  /**
   * Trims cleanly around the single deskewed text line so Tesseract LSTM sees pure characters + quiet white margin.
   */
  function trimToActiveTextBand(hp, w, h) {
    const rowEnergy = new Float32Array(h);
    for (let y = 2; y < h - 2; y++) {
      const r = y * w;
      let e = 0;
      for (let x = 6; x < w - 6; x++) {
        e += Math.abs(hp[r + x + 2] - hp[r + x - 2]);
      }
      rowEnergy[y] = e / Math.max(1, w - 12);
    }

    const halfWin = clamp(Math.round(h * 0.14), 8, 26);
    let peakY = Math.round(h * 0.5);
    let bestS = -1;
    for (let y = halfWin + 1; y < h - halfWin - 1; y++) {
      let s = 0;
      for (let dy = -halfWin; dy <= halfWin; dy++) s += rowEnergy[y + dy];
      if (s > bestS) { bestS = s; peakY = y; }
    }

    const pVal = Math.max(0.01, rowEnergy[peakY]);
    let y0 = peakY, y1 = peakY;
    while (y0 > 1 && rowEnergy[y0 - 1] >= pVal * 0.16 && (peakY - y0) < halfWin * 2.2) y0--;
    while (y1 < h - 2 && rowEnergy[y1 + 1] >= pVal * 0.16 && (y1 - peakY) < halfWin * 2.2) y1++;

    const padY = Math.max(10, Math.round((y1 - y0 + 1) * 0.42));
    y0 = clamp(y0 - padY, 0, h - 16);
    y1 = clamp(y1 + padY, y0 + 16, h - 1);

    // Horizontal trim
    const colEnergy = new Float32Array(w);
    for (let x = 4; x < w - 4; x++) {
      let c = 0;
      for (let y = y0; y <= y1; y++) {
        const idx = y * w + x;
        c += Math.abs(hp[idx + 2] - hp[idx - 2]);
      }
      colEnergy[x] = c / Math.max(1, y1 - y0 + 1);
    }
    const cw = clamp(Math.round(w * 0.025), 8, 22);
    const colSmooth = new Float32Array(w);
    let maxCol = 0.01;
    for (let x = cw; x < w - cw; x++) {
      let s = 0;
      for (let dx = -cw; dx <= cw; dx++) s += colEnergy[x + dx];
      colSmooth[x] = s / (2 * cw + 1);
      if (colSmooth[x] > maxCol) maxCol = colSmooth[x];
    }

    let x0 = 0, x1 = w - 1;
    for (let x = cw; x < w - cw; x++) { if (colSmooth[x] >= maxCol * 0.20) { x0 = x; break; } }
    for (let x = w - cw - 1; x >= cw; x--) { if (colSmooth[x] >= maxCol * 0.20) { x1 = x; break; } }
    if (x1 - x0 < w * 0.22) {
      x0 = 0; x1 = w - 1;
    } else {
      x0 = clamp(x0 - 24, 0, w - 24);
      x1 = clamp(x1 + 24, x0 + 24, w - 1);
    }

    return { x0, y0, x1, y1 };
  }

  function wrapWhiteBorderRGBA(grayInkOnWhite, w, h, pad) {
    const ow = w + pad * 2;
    const oh = h + pad * 2;
    const out = new Uint8ClampedArray(ow * oh * 4);
    out.fill(255);
    for (let y = 0; y < h; y++) {
      const sRow = y * w;
      const dRow = (y + pad) * ow;
      for (let x = 0; x < w; x++) {
        const v = grayInkOnWhite[sRow + x];
        const p = (dRow + x + pad) * 4;
        out[p] = v; out[p + 1] = v; out[p + 2] = v; out[p + 3] = 255;
      }
    }
    return { rgba: out, width: ow, height: oh };
  }

  /**
   * Main Night-Vision & Adaptive Close-Up Recovery Pipeline:
   * - Masks out any solid bright card shelf edge smoothly into local dark LCD background (never clips tilted letters!)
   * - Dynamically upscales tiny 6px wide-shot text up to 5.4x OR anti-alias downscales huge 200px close-up text down to 0.42x
   *   so Tesseract ALWAYS receives crisp ~40px cap-height characters with zero LCD moire!
   */
  function buildNightVisionVariants(rgba, imgW, imgH, roi, options) {
    const opts = Object.assign({
      gain: 1.0,
      thresholdBias: 0,
      manualTiltDeg: null
    }, options || {});

    const rx = clamp(Math.round(roi.x), 0, imgW - 8);
    const ry = clamp(Math.round(roi.y), 0, imgH - 8);
    const rw = clamp(Math.round(roi.w), 8, imgW - rx);
    const rh = clamp(Math.round(roi.h), 8, imgH - ry);

    const roiLuma = new Float32Array(rw * rh);
    for (let y = 0; y < rh; y++) {
      const sOff = ((ry + y) * imgW + rx) * 4;
      const dOff = y * rw;
      for (let x = 0; x < rw; x++) {
        const p = sOff + x * 4;
        roiLuma[dOff + x] = 0.34 * rgba[p] + 0.54 * rgba[p + 1] + 0.12 * rgba[p + 2];
      }
    }

    // 1. Replace any solid bright card border (where local 11x5 mean is much brighter than dark LCD background)
    //    with darkMed BEFORE resampling so tilted characters near a card edge never get clipped OR ringed!
    const rawSorted = Array.from(roiLuma).sort(function (a, b) { return a - b; });
    const darkMed = rawSorted[Math.floor(rawSorted.length * 0.32)] || 18;
    const preInteg = buildIntegralImages(roiLuma, rw, rh);
    const cardMaskCeil = Math.max(darkMed + 62, darkMed * 2.55);
    const cleanRoi = new Float32Array(rw * rh);
    const preHp = new Float32Array(rw * rh);
    const preRadX = Math.max(6, Math.round(rh * 0.28));
    const preRadY = Math.max(4, Math.round(rh * 0.20));

    for (let y = 0; y < rh; y++) {
      for (let x = 0; x < rw; x++) {
        const idx = y * rw + x;
        const locMean = boxMean(preInteg, x, y, Math.max(5, Math.round(rh * 0.18)), Math.max(3, Math.round(rh * 0.12)));
        if (locMean > cardMaskCeil && roiLuma[idx] > darkMed + 45) {
          cleanRoi[idx] = darkMed;
          preHp[idx] = 0;
        } else {
          cleanRoi[idx] = roiLuma[idx];
          preHp[idx] = Math.max(0, roiLuma[idx] - boxMean(preInteg, x, y, preRadX, preRadY));
        }
      }
    }

    const autoTilt = (opts.manualTiltDeg !== null && !Number.isNaN(opts.manualTiltDeg))
      ? opts.manualTiltDeg
      : estimateTextTiltDeg(preHp, rw, rh);

    // 2. Multi-Scale Adaptive Normalization:
    //    - Scale A (~68px strip height -> ~24px glyphs): keeps 6px JPEG wide-shot digits ('34') & 12MP macro close-ups crisp without over-magnifying blur!
    //    - Scale B (~96px strip height -> ~35px glyphs): optimal for Night-Vision local background subtraction on ultra-dimmed strokes!
    const scaleCompactY = clamp(Math.min(68.0 / Math.max(14, rh), (560.0 / Math.max(60, rw)) * 1.12), 0.30, 3.8);
    const upCompact = adaptiveDeskewAndResample(cleanRoi, rw, rh, autoTilt, scaleCompactY * 1.14, scaleCompactY, darkMed);
    const compInteg = buildIntegralImages(upCompact.data, upCompact.width, upCompact.height);
    const compHp = new Float32Array(upCompact.width * upCompact.height);
    const cBgX = Math.max(18, Math.round(upCompact.height * 0.40));
    const cBgY = Math.max(12, Math.round(upCompact.height * 0.26));
    for (let y = 0; y < upCompact.height; y++) {
      const r = y * upCompact.width;
      for (let x = 0; x < upCompact.width; x++) {
        compHp[r + x] = Math.max(0, upCompact.data[r + x] - boxMean(compInteg, x, y, cBgX, cBgY));
      }
    }
    const trimComp = trimToActiveTextBand(compHp, upCompact.width, upCompact.height);
    const cw = trimComp.x1 - trimComp.x0 + 1;
    const ch = trimComp.y1 - trimComp.y0 + 1;
    const compTrimRaw = new Float32Array(cw * ch);
    for (let y = 0; y < ch; y++) {
      for (let x = 0; x < cw; x++) {
        compTrimRaw[y * cw + x] = upCompact.data[(trimComp.y0 + y) * upCompact.width + (trimComp.x0 + x)];
      }
    }
    const compSorted = Array.from(compTrimRaw).sort(function (a, b) { return a - b; });
    const compLo = compSorted[Math.floor(compSorted.length * 0.26)] || 10;
    const compHi = compSorted[Math.floor(compSorted.length * 0.996)] || 80;
    const compSpan = Math.max(2.0, compHi - compLo);

    const scaleByH = 96.0 / Math.max(14, rh);
    const scaleByW = 740.0 / Math.max(60, rw);
    const scaleY = clamp(Math.min(scaleByH, scaleByW * 1.12), 0.35, 5.2);
    const scaleX = scaleY * 1.14;
    const up = adaptiveDeskewAndResample(cleanRoi, rw, rh, autoTilt, scaleX, scaleY, darkMed);
    const uw = up.width;
    const uh = up.height;

    // 3. Wide-radius Local Background Subtraction (flattens uneven night glare & modal backdrop scrims!)
    const integ = buildIntegralImages(up.data, uw, uh);
    const rBgX = Math.max(26, Math.round(uh * 0.40));
    const rBgY = Math.max(18, Math.round(uh * 0.26));
    const rSharp = 2;
    const unsharpStrength = scaleY >= 1.6 ? 0.38 : 0.0;
    const hpFull = new Float32Array(uw * uh);

    for (let y = 0; y < uh; y++) {
      const row = y * uw;
      for (let x = 0; x < uw; x++) {
        const center = up.data[row + x];
        const near = boxMean(integ, x, y, rSharp, rSharp);
        const bg = boxMean(integ, x, y, rBgX, rBgY);
        const unsharp = center + unsharpStrength * (center - near);
        hpFull[row + x] = Math.max(0, unsharp - bg);
      }
    }

    // 4. Trim cleanly around the deskewed text island
    const trim = trimToActiveTextBand(hpFull, uw, uh);
    const fw = trim.x1 - trim.x0 + 1;
    const fh = trim.y1 - trim.y0 + 1;
    const hp = new Float32Array(fw * fh);
    const rawTrim = new Float32Array(fw * fh);

    for (let y = 0; y < fh; y++) {
      for (let x = 0; x < fw; x++) {
        const sIdx = (trim.y0 + y) * uw + (trim.x0 + x);
        hp[y * fw + x] = hpFull[sIdx];
        rawTrim[y * fw + x] = up.data[sIdx];
      }
    }

    const hpSamples = Array.from(hp).sort(function (a, b) { return a - b; });
    const hpLo = hpSamples[Math.floor(hpSamples.length * 0.28)] || 0;
    const hpHi = hpSamples[Math.floor(hpSamples.length * 0.996)] || 8;
    const hpSpan = Math.max(1.2, hpHi - hpLo);

    const rawSamples = Array.from(rawTrim).sort(function (a, b) { return a - b; });
    const rawLo = rawSamples[Math.floor(rawSamples.length * 0.25)] || 10;
    const rawHi = rawSamples[Math.floor(rawSamples.length * 0.996)] || 80;
    const rawSpan = Math.max(2.0, rawHi - rawLo);

    const previewRgba = new Uint8ClampedArray(fw * fh * 4);
    const varBicubicPure = new Uint8ClampedArray(cw * ch);
    const varNightLinear = new Uint8ClampedArray(fw * fh);
    const varNightCrisp  = new Uint8ClampedArray(fw * fh);

    const biasShift = (opts.thresholdBias / 100.0) * 0.25;

    for (let i = 0; i < cw * ch; i++) {
      // Variant 1: Compact-Scale Pure Resampled Linear Grayscale (keeps tiny 6px digits & 12MP macro close-ups super clean!)
      const nComp = clamp(((compTrimRaw[i] - compLo) / compSpan) * opts.gain + biasShift, 0, 1);
      varBicubicPure[i] = Math.round(255 * (1.0 - nComp));
    }

    for (let i = 0; i < fw * fh; i++) {
      // Variant 2: Night-Vision Background-Subtracted Smooth Grayscale
      const nHp = clamp(((hp[i] - hpLo) / hpSpan) * opts.gain + biasShift, 0, 1);
      varNightLinear[i] = Math.round(255 * (1.0 - Math.pow(nHp, 0.95)));

      // Variant 3: High-Contrast Crisp Ink (separates faint digits in 1-scrim & 2-scrim dark photos)
      const nCrisp = clamp((nHp - 0.15) / 0.64, 0, 1);
      varNightCrisp[i] = Math.round(255 * (1.0 - Math.pow(nCrisp, 1.32)));

      // Human Night-Vision Preview (high-contrast bright cyan-white on deep slate)
      const pv = Math.round(clamp(Math.pow(nHp, 0.78) * 255, 0, 255));
      const p4 = i * 4;
      previewRgba[p4]     = Math.round(10 + pv * 0.93);
      previewRgba[p4 + 1] = Math.round(16 + pv * 0.96);
      previewRgba[p4 + 2] = Math.round(26 + pv * 0.91);
      previewRgba[p4 + 3] = 255;
    }

    const pad = 24;
    return {
      roi: { x: rx, y: ry, w: rw, h: rh, mode: roi.mode || 'manual' },
      detectedTiltDeg: autoTilt,
      scaleAppliedY: scaleY,
      dynamicSpan: hpSpan,
      preview: { rgba: previewRgba, width: fw, height: fh },
      ocrVariants: [
        Object.assign({ name: 'bicubic-pure' }, wrapWhiteBorderRGBA(varBicubicPure, cw, ch, pad)),
        Object.assign({ name: 'night-linear' }, wrapWhiteBorderRGBA(varNightLinear, fw, fh, pad)),
        Object.assign({ name: 'night-crisp' },  wrapWhiteBorderRGBA(varNightCrisp,  fw, fh, pad))
      ]
    };
  }

  function parseAndNormalizeBssId(rawText) {
    if (!rawText || typeof rawText !== 'string') return null;

    const lines = rawText.toUpperCase().split(/[\r\n]+/);
    let bestCandidate = null;
    let bestScore = -1;

    function fixDigitChar(ch) {
      switch (ch) {
        case 'O': case 'Q': case 'D': return '0';
        case 'I': case 'L': case '|': case '!': return '1';
        case 'Z': return '2';
        case 'S': return '5';
        case 'G': return '6';
        case 'B': return '8';
        default: return (ch >= '0' && ch <= '9') ? ch : '';
      }
    }

    const joined = [rawText.toUpperCase()].concat(lines);
    for (let i = 0; i < joined.length; i++) {
      const compact = joined[i].replace(/[^A-Z0-9:\-]/g, '');
      if (!compact) continue;

      const prefRegex = /(?:B|8)?(?:S|5|8){2}[\-:]*([0-9OQDILZSBG]{10,18})/g;
      let m;
      while ((m = prefRegex.exec(compact)) !== null) {
        const digits = m[1].split('').map(fixDigitChar).join('');
        if (digits.length >= 10 && digits.length <= 18) {
          const lenBonus = (digits.length === 14) ? 60 : (digits.length >= 12 && digits.length <= 16 ? 18 : 4);
          const vfPrefixBonus = digits.startsWith('260') ? 15 : 0;
          const exactPrefixBonus = m[0].startsWith('BSS-') ? 25 : 15;
          const score = 100 + lenBonus + vfPrefixBonus + exactPrefixBonus;
          if (score > bestScore) {
            bestScore = score;
            bestCandidate = { code: 'BSS-' + digits, digits: digits, confidenceTier: 'high', score: score };
          }
        }
      }

      const tailRegex = /\-?([0-9OQDILZSBG]{12,16})/g;
      while ((m = tailRegex.exec(compact)) !== null) {
        const digits = m[1].split('').map(fixDigitChar).join('');
        if (digits.length >= 12 && digits.length <= 16) {
          const hasDash = m[0].startsWith('-');
          const lenBonus = (digits.length === 14) ? 45 : 10;
          const vfPrefixBonus = digits.startsWith('260') ? 12 : 0;
          const score = (hasDash ? 65 : 45) + lenBonus + vfPrefixBonus;
          if (score > bestScore) {
            bestScore = score;
            bestCandidate = { code: 'BSS-' + digits, digits: digits, confidenceTier: hasDash ? 'medium' : 'recovered', score: score };
          }
        }
      }
    }

    return bestCandidate;
  }

  /**
   * Character-by-character consensus merger across multiple OCR variant reads.
   */
  function mergeParsedCandidates(candidates) {
    if (!candidates || !candidates.length) return null;
    const sorted = candidates.slice().sort(function (a, b) { return b.totalWeight - a.totalWeight; });
    const top = sorted[0];

    const sameLen = sorted.filter(function (c) { return c.digits.length === top.digits.length; });
    if (sameLen.length <= 1) return top;

    let mergedDigits = '';
    for (let pos = 0; pos < top.digits.length; pos++) {
      const charWeights = {};
      for (let i = 0; i < sameLen.length; i++) {
        const ch = sameLen[i].digits[pos];
        charWeights[ch] = (charWeights[ch] || 0) + sameLen[i].totalWeight;
      }
      let bestCh = top.digits[pos];
      let bestW = -1;
      for (const k in charWeights) {
        if (charWeights[k] > bestW) {
          bestW = charWeights[k];
          bestCh = k;
        }
      }
      mergedDigits += bestCh;
    }

    return {
      code: 'BSS-' + mergedDigits,
      digits: mergedDigits,
      confidenceTier: top.confidenceTier,
      totalWeight: top.totalWeight
    };
  }

  return {
    autoLocateBssIdRoi: autoLocateBssIdRoi,
    estimateTextTiltDeg: estimateTextTiltDeg,
    buildNightVisionVariants: buildNightVisionVariants,
    parseAndNormalizeBssId: parseAndNormalizeBssId,
    mergeParsedCandidates: mergeParsedCandidates
  };
});
