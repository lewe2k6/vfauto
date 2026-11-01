/**
 * vision.js — Night-Vision Pixel Recovery, Sharp Bicubic & Auto-ROI Engine for VinFast BSS Screens
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
   * Green-weighted luminance maximizes contrast of grey/white LCD subpixels against dark-blue cabinet bezels.
   */
  function extractCleanLuma(rgba, width, height) {
    const luma = new Float32Array(width * height);
    for (let i = 0, p = 0; i < luma.length; i++, p += 4) {
      luma[i] = 0.34 * rgba[p] + 0.54 * rgba[p + 1] + 0.12 * rgba[p + 2];
    }
    return luma;
  }

  /**
   * Automatically locates the narrow horizontal strip containing "ID: BSS-..."
   * Works across:
   *  1) Normal full station screen (below the 2 white cards)
   *  2) Dead-touchscreen stuck popup screen (below the dimmed outer modal / cards)
   *  3) Close-up macro shot / live strip viewfinder crop
   */
  function autoLocateBssIdRoi(rgba, width, height) {
    // Already a horizontal strip crop (from Live Strip Viewfinder or user pre-crop)
    if (width / Math.max(1, height) >= 2.4) {
      return {
        x: Math.round(width * 0.02),
        y: Math.round(height * 0.04),
        w: Math.round(width * 0.96),
        h: Math.round(height * 0.92),
        mode: 'closeup-strip'
      };
    }

    const luma = extractCleanLuma(rgba, width, height);
    const xLo = Math.floor(width * 0.25);
    const xHi = Math.ceil(width * 0.75);
    const sampleStep = Math.max(1, Math.floor((xHi - xLo) / 120));

    const p85 = new Float32Array(height);
    const strokeEnergy = new Float32Array(height);
    const rowBuf = [];

    for (let y = 2; y < height - 2; y++) {
      rowBuf.length = 0;
      let sSum = 0;
      let sCnt = 0;
      const rOff = y * width;
      for (let x = xLo; x < xHi; x += sampleStep) {
        rowBuf.push(luma[rOff + x]);
        if (x >= 3 && x < width - 3) {
          const dx = Math.abs(luma[rOff + x + 2] - luma[rOff + x - 2]);
          const dy = Math.abs(luma[(y + 2) * width + x] - luma[(y - 2) * width + x]);
          const net = dx - 0.55 * dy;
          if (net > 0) sSum += net;
          sCnt++;
        }
      }
      rowBuf.sort(function (a, b) { return a - b; });
      p85[y] = rowBuf.length ? rowBuf[Math.floor(rowBuf.length * 0.85)] : 0;
      strokeEnergy[y] = sCnt ? (sSum / sCnt) : 0;
    }

    const p85Smooth = new Float32Array(height);
    for (let y = 3; y < height - 3; y++) {
      p85Smooth[y] = (p85[y - 2] + p85[y - 1] + p85[y] + p85[y + 1] + p85[y + 2]) / 5.0;
    }

    // Detect steepest bright->dark cliff where cards/outer modal end and dark bottom LCD bezel margin begins.
    const upWin = Math.max(8, Math.round(height * 0.04));
    const dnWin = Math.max(8, Math.round(height * 0.025));
    let bestDropY = -1;

    let y = Math.round(height * 0.15);
    const yEnd = Math.round(height * 0.86) - dnWin;
    while (y < yEnd) {
      let upSum = 0;
      for (let k = 2; k <= upWin + 1; k++) upSum += p85Smooth[Math.max(0, y - k)];
      const upAvg = upSum / upWin;

      let dnSum = 0;
      for (let k = 2; k <= dnWin + 1; k++) dnSum += p85Smooth[Math.min(height - 1, y + k)];
      const dnAvg = dnSum / dnWin;

      if (upAvg >= 88 && dnAvg <= 80 && (upAvg - dnAvg) >= 38) {
        let peakCliff = -1;
        let cliffY = y;
        const zEnd = Math.min(yEnd, y + upWin);
        for (let r = Math.max(4, y - 4); r <= zEnd; r++) {
          let u2 = 0, d2 = 0;
          for (let k = 2; k <= dnWin + 1; k++) d2 += p85Smooth[Math.min(height - 1, r + k)];
          for (let k = 2; k <= upWin + 1; k++) u2 += p85Smooth[Math.max(0, r - k)];
          if ((u2 / upWin) >= 85 && (d2 / dnWin) <= 82) {
            const cliff = p85Smooth[r - 3] - p85Smooth[Math.min(height - 1, r + 3)];
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

    if (bestDropY > 0) {
      // Capture slight margin above bestDropY so tilted left/right text ends are never clipped!
      const roiY = clamp(bestDropY - Math.max(4, Math.round(height * 0.005)), 0, height - 20);
      const roiH = clamp(Math.round(height * 0.035), 24, height - roiY);
      const roiX = Math.round(width * 0.28);
      const roiW = Math.round(width * 0.42);

      return {
        x: roiX,
        y: roiY,
        w: roiW,
        h: roiH,
        dropY: bestDropY,
        mode: 'auto-shelf-anchor'
      };
    }

    // Close-up macro photo without a bright shelf: find the strongest horizontal text-stroke band
    const bandHalf = Math.max(8, Math.round(height * 0.05));
    let peakY = Math.round(height * 0.5);
    let bestScore = -1;
    for (let ry = Math.round(height * 0.08) + bandHalf; ry <= Math.round(height * 0.92) - bandHalf; ry++) {
      let sc = 0;
      for (let dy = -bandHalf; dy <= bandHalf; dy++) sc += strokeEnergy[ry + dy];
      if (sc > bestScore) {
        bestScore = sc;
        peakY = ry;
      }
    }
    const roiH = clamp(Math.round(height * 0.32), 32, height);
    const roiY = clamp(Math.round(peakY - roiH * 0.5), 0, height - roiH);
    return {
      x: Math.round(width * 0.05),
      y: roiY,
      w: Math.round(width * 0.90),
      h: roiH,
      mode: 'closeup-stroke-band'
    };
  }

  /**
   * Estimates text baseline slope in degrees (-6.0 .. +6.0) using horizontal character-stroke gradients.
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
        if (cnt[y] > 12) {
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
        if (cnt[y] > 12) {
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
    const a = -0.55; // Sharp Catmull-Rom bicubic kernel preserves inner digit loops (6, 8, 0, B, S)!
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
   * Sharp Catmull-Rom Bicubic counter-rotation + upscaler.
   */
  function bicubicDeskewAndUpscale(src, sw, sh, angleDeg, scaleX, scaleY) {
    const dw = Math.max(24, Math.round(sw * scaleX));
    const dh = Math.max(20, Math.round(sh * scaleY));
    const dst = new Float32Array(dw * dh);

    const rad = (angleDeg * Math.PI) / 180.0;
    const cosA = Math.cos(rad);
    const sinA = Math.sin(rad);
    const scx = (sw - 1) * 0.5;
    const scy = (sh - 1) * 0.5;
    const dcx = (dw - 1) * 0.5;
    const dcy = (dh - 1) * 0.5;

    function getClamped(x, y) {
      const cx = x < 0 ? 0 : x >= sw ? sw - 1 : x;
      const cy = y < 0 ? 0 : y >= sh ? sh - 1 : y;
      return src[cy * sw + cx];
    }

    for (let dy = 0; dy < dh; dy++) {
      const uy = (dy - dcy) / scaleY;
      const dRow = dy * dw;
      for (let dx = 0; dx < dw; dx++) {
        const ux = (dx - dcx) / scaleX;
        const sx = scx + ux * cosA - uy * sinA;
        const sy = scy + ux * sinA + uy * cosA;

        const ix = Math.floor(sx);
        const iy = Math.floor(sy);
        const fx = sx - ix;
        const fy = sy - iy;

        const r0 = cubicWeight(getClamped(ix - 1, iy - 1), getClamped(ix, iy - 1), getClamped(ix + 1, iy - 1), getClamped(ix + 2, iy - 1), fx);
        const r1 = cubicWeight(getClamped(ix - 1, iy),     getClamped(ix, iy),     getClamped(ix + 1, iy),     getClamped(ix + 2, iy),     fx);
        const r2 = cubicWeight(getClamped(ix - 1, iy + 1), getClamped(ix, iy + 1), getClamped(ix + 1, iy + 1), getClamped(ix + 2, iy + 1), fx);
        const r3 = cubicWeight(getClamped(ix - 1, iy + 2), getClamped(ix, iy + 2), getClamped(ix + 1, iy + 2), getClamped(ix + 2, iy + 2), fx);
        dst[dRow + dx] = cubicWeight(r0, r1, r2, r3, fy);
      }
    }
    return { data: dst, width: dw, height: dh };
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

  function boxStats(integ, x, y, rx, ry) {
    const radY = (ry === undefined) ? rx : ry;
    const x1 = Math.max(0, x - rx);
    const y1 = Math.max(0, y - radY);
    const x2 = Math.min(integ.w, x + rx + 1);
    const y2 = Math.min(integ.h, y + radY + 1);
    const area = Math.max(1, (x2 - x1) * (y2 - y1));
    const st = integ.stride;

    const a = y1 * st + x1;
    const b = y1 * st + x2;
    const c = y2 * st + x1;
    const d = y2 * st + x2;

    const s = integ.sum[d] - integ.sum[b] - integ.sum[c] + integ.sum[a];
    const sq = integ.sqSum[d] - integ.sqSum[b] - integ.sqSum[c] + integ.sqSum[a];
    const mean = s / area;
    const variance = Math.max(0, sq / area - mean * mean);
    return { mean, std: Math.sqrt(variance) };
  }

  /**
   * Finds tight horizontal & vertical bounds of the single text line inside the deskewed high-pass strip.
   */
  function trimToActiveTextBand(hp, rawUp, w, h) {
    const rawSorted = [];
    for (let i = 0; i < rawUp.length; i += 7) rawSorted.push(rawUp[i]);
    rawSorted.sort(function (a, b) { return a - b; });
    const darkMed = rawSorted[Math.floor(rawSorted.length * 0.35)] || 20;
    const brightCardCeiling = Math.max(darkMed + 65, darkMed * 2.5);

    const rowEnergy = new Float32Array(h);
    for (let y = 2; y < h - 2; y++) {
      const r = y * w;
      let e = 0;
      for (let x = 6; x < w - 6; x++) {
        if (rawUp[r + x] > brightCardCeiling) continue;
        e += Math.abs(hp[r + x + 2] - hp[r + x - 2]);
      }
      rowEnergy[y] = e / Math.max(1, w - 12);
    }

    const halfWin = clamp(Math.round(h * 0.14), 8, 28);
    let peakY = Math.round(h * 0.5);
    let bestS = -1;
    for (let y = halfWin + 1; y < h - halfWin - 1; y++) {
      let s = 0;
      for (let dy = -halfWin; dy <= halfWin; dy++) s += rowEnergy[y + dy];
      if (s > bestS) { bestS = s; peakY = y; }
    }

    const pVal = Math.max(0.01, rowEnergy[peakY]);
    let y0 = peakY, y1 = peakY;
    while (y0 > 1 && rowEnergy[y0 - 1] >= pVal * 0.14 && (peakY - y0) < halfWin * 2.2) y0--;
    while (y1 < h - 2 && rowEnergy[y1 + 1] >= pVal * 0.14 && (y1 - peakY) < halfWin * 2.2) y1++;

    const padY = Math.max(10, Math.round((y1 - y0 + 1) * 0.45));
    y0 = clamp(y0 - padY, 0, h - 16);
    y1 = clamp(y1 + padY, y0 + 16, h - 1);

    // Horizontal trim
    const colEnergy = new Float32Array(w);
    for (let x = 4; x < w - 4; x++) {
      let c = 0;
      for (let y = y0; y <= y1; y++) {
        const idx = y * w + x;
        if (rawUp[idx] <= brightCardCeiling) c += Math.abs(hp[idx + 2] - hp[idx - 2]);
      }
      colEnergy[x] = c / Math.max(1, y1 - y0 + 1);
    }
    const cw = 20;
    const colSmooth = new Float32Array(w);
    let maxCol = 0.01;
    for (let x = cw; x < w - cw; x++) {
      let s = 0;
      for (let dx = -cw; dx <= cw; dx++) s += colEnergy[x + dx];
      colSmooth[x] = s / (2 * cw + 1);
      if (colSmooth[x] > maxCol) maxCol = colSmooth[x];
    }

    let x0 = 0, x1 = w - 1;
    for (let x = cw; x < w - cw; x++) { if (colSmooth[x] >= maxCol * 0.18) { x0 = x; break; } }
    for (let x = w - cw - 1; x >= cw; x--) { if (colSmooth[x] >= maxCol * 0.18) { x1 = x; break; } }
    if (x1 - x0 < w * 0.20) {
      x0 = 0; x1 = w - 1;
    } else {
      x0 = clamp(x0 - 28, 0, w - 24);
      x1 = clamp(x1 + 28, x0 + 24, w - 1);
    }

    return { x0, y0, x1, y1, brightCardCeiling };
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
   * Main Night-Vision Recovery Pipeline:
   * Preserves delicate inner loops on tiny fonts via Catmull-Rom Bicubic + Smooth Linear Grayscale,
   * while pulling ultra-dim double-scrim text out of darkness via Wide-Radius Local Background Subtraction.
   */
  function buildNightVisionVariants(rgba, imgW, imgH, roi, options) {
    const opts = Object.assign({
      gain: 1.0,           // 1.0 = natural smooth anti-aliased strokes (user slider: 0.5 .. 2.5)
      thresholdBias: 0,    // -35 .. +35
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

    // 1. Pre-highpass on native ROI (masking out any bright card edge) to measure true character line tilt
    const preInteg = buildIntegralImages(roiLuma, rw, rh);
    const preHp = new Float32Array(rw * rh);
    const rawSorted = Array.from(roiLuma).sort(function (a, b) { return a - b; });
    const darkCeil = (rawSorted[Math.floor(rawSorted.length * 0.35)] || 20) * 2.4 + 55;
    const preRad = Math.max(5, Math.round(rh * 0.22));
    for (let y = 0; y < rh; y++) {
      for (let x = 0; x < rw; x++) {
        const idx = y * rw + x;
        if (roiLuma[idx] > darkCeil) { preHp[idx] = 0; continue; }
        preHp[idx] = Math.max(0, roiLuma[idx] - boxStats(preInteg, x, y, preRad).mean);
      }
    }

    const autoTilt = (opts.manualTiltDeg !== null && !Number.isNaN(opts.manualTiltDeg))
      ? opts.manualTiltDeg
      : estimateTextTiltDeg(preHp, rw, rh);

    // 2. Sharp Catmull-Rom Bicubic Deskew + Upscale (scale ~3.5x on small strips, ~1.8-2.5x on close-ups)
    const scaleY = clamp(128.0 / Math.max(18, rh), 1.5, 4.0);
    const scaleX = scaleY * 1.06; // Slight 6% horizontal breathing room prevents adjacent digits from kissing
    const up = bicubicDeskewAndUpscale(roiLuma, rw, rh, autoTilt, scaleX, scaleY);
    const uw = up.width;
    const uh = up.height;

    // 3. Wide-radius Local Background Subtraction (flattens uneven night lighting & modal dark scrims!)
    const integ = buildIntegralImages(up.data, uw, uh);
    const rBgX = Math.max(24, Math.round(uh * 0.38));
    const rBgY = Math.max(16, Math.round(uh * 0.24));
    const rSharp = 2;
    const hpFull = new Float32Array(uw * uh);

    for (let y = 0; y < uh; y++) {
      const row = y * uw;
      for (let x = 0; x < uw; x++) {
        const center = up.data[row + x];
        const near = boxStats(integ, x, y, rSharp, rSharp).mean;
        const bg = boxStats(integ, x, y, rBgX, rBgY).mean;
        // Mild unsharp lift (0.35) opens inner loops of '6' and '8' without creating ringing halos
        const unsharp = center + 0.35 * (center - near);
        hpFull[row + x] = Math.max(0, unsharp - bg);
      }
    }

    // 4. Trim cleanly around the horizontal text line so card/bezel edges are excluded
    const trim = trimToActiveTextBand(hpFull, up.data, uw, uh);
    const fw = trim.x1 - trim.x0 + 1;
    const fh = trim.y1 - trim.y0 + 1;
    const hp = new Float32Array(fw * fh);
    const rawTrim = new Float32Array(fw * fh);

    for (let y = 0; y < fh; y++) {
      for (let x = 0; x < fw; x++) {
        const sIdx = (trim.y0 + y) * uw + (trim.x0 + x);
        const masked = up.data[sIdx] > trim.brightCardCeiling;
        hp[y * fw + x] = masked ? 0 : hpFull[sIdx];
        rawTrim[y * fw + x] = masked ? (trim.brightCardCeiling * 0.3) : up.data[sIdx];
      }
    }

    // Measure percentiles for both direct local-stretched greyscale AND high-pass night-vision
    const hpSamples = Array.from(hp).sort(function (a, b) { return a - b; });
    const hpLo = hpSamples[Math.floor(hpSamples.length * 0.25)] || 0;
    const hpHi = hpSamples[Math.floor(hpSamples.length * 0.997)] || 8;
    const hpSpan = Math.max(1.2, hpHi - hpLo);

    const rawSamples = Array.from(rawTrim).sort(function (a, b) { return a - b; });
    const rawLo = rawSamples[Math.floor(rawSamples.length * 0.22)] || 10;
    const rawHi = rawSamples[Math.floor(rawSamples.length * 0.997)] || 80;
    const rawSpan = Math.max(2.0, rawHi - rawLo);

    const previewRgba = new Uint8ClampedArray(fw * fh * 4);
    const varBicubicPure = new Uint8ClampedArray(fw * fh);
    const varNightLinear = new Uint8ClampedArray(fw * fh);
    const varNightCrisp  = new Uint8ClampedArray(fw * fh);

    const biasShift = (opts.thresholdBias / 100.0) * 0.25;

    for (let i = 0; i < fw * fh; i++) {
      // Variant 1: Pure Catmull-Rom Bicubic Linear Inverted Grayscale (zero morphological distortion!)
      const nRaw = clamp(((rawTrim[i] - rawLo) / rawSpan) * opts.gain + biasShift, 0, 1);
      varBicubicPure[i] = Math.round(255 * (1.0 - nRaw));

      // Variant 2: Night-Vision Background-Subtracted Smooth Grayscale (defeats uneven glare & modal scrims!)
      const nHp = clamp(((hp[i] - hpLo) / hpSpan) * opts.gain + biasShift, 0, 1);
      varNightLinear[i] = Math.round(255 * (1.0 - Math.pow(nHp, 0.95)));

      // Variant 3: High-Contrast Crisp Ink (for ultra-faint strokes)
      const nCrisp = clamp((nHp - 0.16) / 0.62, 0, 1);
      varNightCrisp[i] = Math.round(255 * (1.0 - Math.pow(nCrisp, 1.35)));

      // Human Night-Vision Preview (high-contrast bright cyan-white on deep slate)
      const pv = Math.round(clamp(Math.pow(nHp, 0.78) * 255, 0, 255));
      const p4 = i * 4;
      previewRgba[p4]     = Math.round(12 + pv * 0.92);
      previewRgba[p4 + 1] = Math.round(18 + pv * 0.96);
      previewRgba[p4 + 2] = Math.round(28 + pv * 0.90);
      previewRgba[p4 + 3] = 255;
    }

    const pad = 24;
    return {
      roi: { x: rx, y: ry, w: rw, h: rh, mode: roi.mode || 'manual' },
      detectedTiltDeg: autoTilt,
      dynamicSpan: hpSpan,
      preview: { rgba: previewRgba, width: fw, height: fh },
      ocrVariants: [
        Object.assign({ name: 'bicubic-pure' }, wrapWhiteBorderRGBA(varBicubicPure, fw, fh, pad)),
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
          const lenBonus = (digits.length === 14) ? 50 : (digits.length >= 12 && digits.length <= 16 ? 20 : 5);
          const exactPrefixBonus = m[0].startsWith('BSS-') ? 25 : 15;
          const score = 100 + lenBonus + exactPrefixBonus;
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
          const lenBonus = (digits.length === 14) ? 35 : 10;
          const score = (hasDash ? 65 : 45) + lenBonus;
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
   * Character-by-character consensus merger across multiple OCR variant reads!
   * If Variant 1 reads "BSS-26063041024125" and Variant 2 reads "BSS-20063041024325",
   * merges high-confidence digit positions cleanly!
   */
  function mergeParsedCandidates(candidates) {
    if (!candidates || !candidates.length) return null;
    const sorted = candidates.slice().sort(function (a, b) { return b.totalWeight - a.totalWeight; });
    const top = sorted[0];

    // Group all candidates sharing the same digit length (especially 14 digits) to vote per-digit!
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
