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

  function rgbaToDataUrl(rgba, width, height) {
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
   * read it via jsQR solely to show a "100% Cross-Verified" badge alongside the bottom-text OCR!
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
      const variantCanvas = rgbaToDataUrl(v.rgba, v.width, v.height);
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
        const res6 = await wk.recognize(rgbaToDataUrl(v.rgba, v.width, v.height));
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
   * Sanitizes manual user input: strips any accidental "ID:", spaces, or lowercase letters
   * so the QR payload is ALWAYS pure "BSS-..." matching the real VinFast cabinet!
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
   * Draws a razor-sharp QR matrix onto a target <canvas> (matching the VinFast BSS cabinet card style).
   */
  function renderCrispQrToCanvas(canvas, payloadText, opts) {
    const options = Object.assign({
      sizePx: 320,
      quietModules: 4,
      showCornerBrackets: true
    }, opts || {});

    const cleanPayload = sanitizeUserBssInput(payloadText);
    if (!cleanPayload || typeof qrcode !== 'function') return false;

    // TypeNumber 0 = auto-fit (18-char "BSS-26063041024325" fits cleanly in Version 2 / ECC 'M')
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

    // Soft ice-blue outer card background like VinFast cabinet if brackets enabled, pure white inside quiet zone
    if (options.showCornerBrackets) {
      ctx.fillStyle = '#E8EEFA';
      ctx.fillRect(0, 0, finalSize, finalSize);
    }
    ctx.fillStyle = '#FFFFFF';
    ctx.fillRect(bracketPad, bracketPad, qrDrawPx, qrDrawPx);

    // Draw crisp dark modules
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

    // Draw blue VinFast-style corner alignment brackets outside the 4-module white quiet zone
    if (options.showCornerBrackets) {
      const bInset = Math.round(bracketPad * 0.48);
      const bLen = Math.round(cellPx * 2.4);
      ctx.strokeStyle = '#1E4DB7';
      ctx.lineWidth = Math.max(3, Math.round(cellPx * 0.36));
      ctx.lineCap = 'square';

      const minC = bInset;
      const maxC = finalSize - bInset;

      ctx.beginPath();
      // Top-left
      ctx.moveTo(minC, minC + bLen); ctx.lineTo(minC, minC); ctx.lineTo(minC + bLen, minC);
      // Top-right
      ctx.moveTo(maxC - bLen, minC); ctx.lineTo(maxC, minC); ctx.lineTo(maxC, minC + bLen);
      // Bottom-left
      ctx.moveTo(minC, maxC - bLen); ctx.lineTo(minC, maxC); ctx.lineTo(minC + bLen, maxC);
      // Bottom-right
      ctx.moveTo(maxC - bLen, maxC); ctx.lineTo(maxC, maxC); ctx.lineTo(maxC, maxC - bLen);
      ctx.stroke();
    }

    return true;
  }

  /**
   * Builds a high-resolution standalone PNG card (1000 x 1220) for saving to iPhone Photos / sharing.
   */
  function buildDownloadableQrCardCanvas(payloadText, stationNote) {
    const cleanPayload = sanitizeUserBssInput(payloadText);
    const card = document.createElement('canvas');
    card.width = 1000;
    card.height = 1220;
    const ctx = card.getContext('2d');

    // Deep navy cabinet frame + crisp white inner card
    ctx.fillStyle = '#0B162C';
    ctx.fillRect(0, 0, card.width, card.height);

    ctx.fillStyle = '#FFFFFF';
    ctx.beginPath();
    if (ctx.roundRect) ctx.roundRect(60, 60, 880, 1060, 36);
    else ctx.rect(60, 60, 880, 1060);
    ctx.fill();

    ctx.fillStyle = '#111827';
    ctx.font = '700 38px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif';
    ctx.textAlign = 'center';
    ctx.fillText('Quét mã để đổi Pin VinFast', 500, 148);

    if (stationNote && stationNote.trim()) {
      ctx.fillStyle = '#1D4ED8';
      ctx.font = '600 28px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif';
      ctx.fillText(stationNote.trim(), 500, 198);
    }

    const qrSub = document.createElement('canvas');
    renderCrispQrToCanvas(qrSub, cleanPayload, { sizePx: 680, quietModules: 4, showCornerBrackets: true });
    const qx = Math.round((card.width - qrSub.width) * 0.5);
    const qy = 235;
    ctx.drawImage(qrSub, qx, qy);

    ctx.fillStyle = '#0F172A';
    ctx.font = '700 40px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace';
    ctx.fillText(cleanPayload, 500, qy + qrSub.height + 76);

    ctx.fillStyle = '#64748B';
    ctx.font = '500 24px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif';
    ctx.fillText('Đã lọc sạch tiền tố "ID: " — Chuẩn 1:1 mã trạm gốc', 500, qy + qrSub.height + 122);

    ctx.fillStyle = '#94A3B8';
    ctx.font = '500 22px ui-monospace, SFMono-Regular, monospace';
    ctx.fillText('ID: ' + cleanPayload, 500, 1172);

    return card;
  }

  root.BSSOcrQr = {
    getOcrWorker: getOcrWorker,
     isWorkerReady: function () { return workerReady; },
    tryDecodeOriginalCabinetQr: tryDecodeOriginalCabinetQr,
    recognizeBssFromVariants: recognizeBssFromVariants,
    sanitizeUserBssInput: sanitizeUserBssInput,
    renderCrispQrToCanvas: renderCrispQrToCanvas,
    buildDownloadableQrCardCanvas: buildDownloadableQrCardCanvas
  };
})(typeof self !== 'undefined' ? self : this);
