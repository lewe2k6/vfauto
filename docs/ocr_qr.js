/**
 * ocr_qr.js — Multi-Exposure Tesseract OCR Orchestrator & Exact 1:1 VinFast BSS QR Renderer
 */
(function (root) {
  'use strict';

  let workerPromise = null;
  let workerReady = false;

  async function getOcrWorker(onStatus) {
    if (workerPromise) return workerPromise;
    workerPromise = (async function () {
      if (typeof Tesseract === 'undefined') {
        throw new Error('Chưa tải được thư viện nhận diện chữ Tesseract.js');
      }
      if (onStatus) onStatus('Đang khởi tạo nhân đọc chữ Offline (lần đầu ~2 giây)...');
      const localWorkerUrl = (typeof window !== 'undefined' && window.location)
        ? new URL('./vendor/worker.min.js', window.location.href).href
        : undefined;
      const loggerFn = function (m) {
        if (onStatus && m && m.status === 'loading language traineddata') {
          const pct = Math.round((m.progress || 0) * 100);
          onStatus('Đang nạp bộ chữ Offline (' + pct + '%)...');
        }
      };
      let wk;
      try {
        wk = await Tesseract.createWorker('eng', 1, {
          workerPath: localWorkerUrl,
          workerBlobURL: false,
          logger: loggerFn
        });
      } catch (_) {
        wk = await Tesseract.createWorker('eng', 1, {
          workerPath: localWorkerUrl,
          workerBlobURL: true,
          logger: loggerFn
        });
      }
      await wk.setParameters({
        tessedit_pageseg_mode: '7', // PSM.SINGLE_LINE
        tessedit_char_whitelist: 'ID:BS-0123456789 '
      });
      workerReady = true;
      return wk;
    })();

    try {
      return await workerPromise;
    } catch (err) {
      workerPromise = null;
      workerReady = false;
      throw err;
    }
  }

  function rgbaToCanvas(rgba, width, height) {
    const c = document.createElement('canvas');
    c.width = width;
    c.height = height;
    const ctx = c.getContext('2d');
    const imgData = new ImageData(new Uint8ClampedArray(rgba), width, height);
    ctx.putImageData(imgData, 0, 0);
    return c;
  }

  /**
   * Optional cross-check: if the uploaded photo still has an unblocked original QR on the left,
   * read it via jsQR solely to show a "100% Cross-Verified" badge alongside the bottom-text OCR.
   */
  function tryDecodeOriginalCabinetQr(rgba, width, height) {
    if (typeof jsQR !== 'function') return null;
    try {
      const hit = jsQR(rgba, width, height, { inversionAttempts: 'dontInvert' });
      if (hit && hit.data) {
        const clean = hit.data.trim().toUpperCase();
        if (/^BSS-\d{8,20}$/.test(clean)) return clean;
      }
    } catch (_) {}
    return null;
  }

  /**
   * Runs 3 Night-Vision OCR variants and merges per-character votes.
   */
  async function recognizeBssFromVariants(visionResult, onStatus) {
    const wk = await getOcrWorker(onStatus);
    const candidates = [];
    const rawLogs = [];

    for (let i = 0; i < visionResult.ocrVariants.length; i++) {
      const v = visionResult.ocrVariants[i];
      if (onStatus) {
        onStatus('Đang soi Kính Đêm tầng ' + (i + 1) + '/' + visionResult.ocrVariants.length + ' (' + v.name + ')...');
      }
      const variantCanvas = rgbaToCanvas(v.rgba, v.width, v.height);
      const res = await wk.recognize(variantCanvas);
      const txt = (res && res.data && res.data.text) ? res.data.text.trim() : '';
      const conf = (res && res.data && typeof res.data.confidence === 'number') ? res.data.confidence : 0;
      const parsed = root.BSSVision.parseAndNormalizeBssId(txt);
      rawLogs.push({ variant: v.name, raw: txt, confidence: conf, parsed: parsed ? parsed.code : null });

      if (parsed) {
        candidates.push(Object.assign({}, parsed, {
          variant: v.name,
          ocrConfidence: conf,
          totalWeight: parsed.score + conf * 0.65
        }));
      }
    }

    // Fallback: if SINGLE_LINE missed due to multi-line noise inside manual crop, try SINGLE_BLOCK (PSM 6) on night-linear
    if (!candidates.length && visionResult.ocrVariants[1]) {
      if (onStatus) onStatus('Đang quét sâu chế độ đa dòng cho vùng ảnh mờ...');
      await wk.setParameters({ tessedit_pageseg_mode: '6', tessedit_char_whitelist: 'ID:BS-0123456789 ' });
      try {
        const v = visionResult.ocrVariants[1];
        const res6 = await wk.recognize(rgbaToCanvas(v.rgba, v.width, v.height));
        const txt6 = (res6 && res6.data && res6.data.text) ? res6.data.text.trim() : '';
        const parsed6 = root.BSSVision.parseAndNormalizeBssId(txt6);
        if (parsed6) {
          candidates.push(Object.assign({}, parsed6, {
            variant: 'block-fallback',
            ocrConfidence: res6.data.confidence || 0,
            totalWeight: parsed6.score + (res6.data.confidence || 0) * 0.5
          }));
        }
      } finally {
        await wk.setParameters({ tessedit_pageseg_mode: '7', tessedit_char_whitelist: 'ID:BS-0123456789 ' });
      }
    }

    const merged = root.BSSVision.mergeParsedCandidates(candidates);
    return {
      best: merged,
      rawLogs: rawLogs
    };
  }

  /**
   * Sanitizes manual input: strips any accidental "ID:", spaces, or lowercase letters
   * so the QR payload is ALWAYS pure "BSS-..." matching the real VinFast cabinet.
   */
  function sanitizeUserBssInput(inputStr) {
    if (!inputStr) return '';
    let s = inputStr.toUpperCase().trim();
    s = s.replace(/^ID\s*:\s*/i, '').replace(/\s+/g, '');
    if (/^\d{8,20}$/.test(s)) {
      return 'BSS-' + s;
    }
    if (/^BSS\d{8,20}$/.test(s)) {
      return 'BSS-' + s.slice(3);
    }
    return s;
  }

  /**
   * Draws a razor-sharp QR matrix onto a target <canvas> for direct phone-to-phone scanning.
   */
  function renderCrispQrToCanvas(canvas, payloadText, opts) {
    const options = Object.assign({
      sizePx: 340,
      quietModules: 4,
      showCornerBrackets: true
    }, opts || {});

    const cleanPayload = sanitizeUserBssInput(payloadText);
    if (!cleanPayload || typeof qrcode !== 'function') return false;

    const qr = qrcode(0, 'M');
    qr.addData(cleanPayload, 'Byte');
    qr.make();

    const modCount = qr.getModuleCount();
    const totalMods = modCount + options.quietModules * 2;
    const cellPx = Math.max(4, Math.floor(options.sizePx / totalMods));
    const qrDrawPx = cellPx * totalMods;
    const bracketPad = options.showCornerBrackets ? Math.round(cellPx * 2.2) : 0;
    const finalSize = qrDrawPx + bracketPad * 2;

    canvas.width = finalSize;
    canvas.height = finalSize;
    const ctx = canvas.getContext('2d');
    ctx.imageSmoothingEnabled = false;

    if (options.showCornerBrackets) {
      ctx.fillStyle = '#E8EEFA';
      ctx.fillRect(0, 0, finalSize, finalSize);
    }
    ctx.fillStyle = '#FFFFFF';
    ctx.fillRect(bracketPad, bracketPad, qrDrawPx, qrDrawPx);

    ctx.fillStyle = '#0B101B';
    for (let r = 0; r < modCount; r++) {
      for (let c = 0; c < modCount; c++) {
        if (qr.isDark(r, c)) {
          const x = bracketPad + (c + options.quietModules) * cellPx;
          const y = bracketPad + (r + options.quietModules) * cellPx;
          ctx.fillRect(x, y, cellPx, cellPx);
        }
      }
    }

    if (options.showCornerBrackets) {
      const bInset = Math.round(bracketPad * 0.48);
      const bLen = Math.round(cellPx * 2.4);
      ctx.strokeStyle = '#1E4DB7';
      ctx.lineWidth = Math.max(3, Math.round(cellPx * 0.36));
      ctx.lineCap = 'square';

      const minC = bInset;
      const maxC = finalSize - bInset;

      ctx.beginPath();
      ctx.moveTo(minC, minC + bLen); ctx.lineTo(minC, minC); ctx.lineTo(minC + bLen, minC);
      ctx.moveTo(maxC - bLen, minC); ctx.lineTo(maxC, minC); ctx.lineTo(maxC, minC + bLen);
      ctx.moveTo(minC, maxC - bLen); ctx.lineTo(minC, maxC); ctx.lineTo(minC + bLen, maxC);
      ctx.moveTo(maxC - bLen, maxC); ctx.lineTo(maxC, maxC); ctx.lineTo(maxC, maxC - bLen);
      ctx.stroke();
    }

    return true;
  }

  root.BSSOcrQr = {
    getOcrWorker: getOcrWorker,
    isWorkerReady: function () { return workerReady; },
    tryDecodeOriginalCabinetQr: tryDecodeOriginalCabinetQr,
    recognizeBssFromVariants: recognizeBssFromVariants,
    sanitizeUserBssInput: sanitizeUserBssInput,
    renderCrispQrToCanvas: renderCrispQrToCanvas
  };
})(typeof self !== 'undefined' ? self : this);
