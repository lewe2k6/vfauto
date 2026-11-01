/**
 * app.js — Pure Photo-Upload Auto Night-Vision BSS QR Rescue Controller (v3)
 */
(function () {
  'use strict';

  // DOM Elements
  const btnPickFile       = document.getElementById('btnPickFile');
  const fileInput         = document.getElementById('fileInput');
  const engineStatusPill  = document.getElementById('engineStatusPill');

  const visionCard        = document.getElementById('visionCard');
  const nightVisionCanvas = document.getElementById('nightVisionCanvas');
  const gainSlider        = document.getElementById('gainSlider');
  const gainVal           = document.getElementById('gainVal');
  const tiltSlider        = document.getElementById('tiltSlider');
  const tiltVal           = document.getElementById('tiltVal');
  const btnReOcr          = document.getElementById('btnReOcr');
  const ocrProgressBox    = document.getElementById('ocrProgressBox');

  const bssCodeInput      = document.getElementById('bssCodeInput');
  const btnCopyCode       = document.getElementById('btnCopyCode');
  const codeValidationMsg = document.getElementById('codeValidationMsg');
  const crossVerifyBadge  = document.getElementById('crossVerifyBadge');

  const qrCard            = document.getElementById('qrCard');
  const qrCanvas          = document.getElementById('qrCanvas');
  const qrCodeCaption     = document.getElementById('qrCodeCaption');
  const btnFullscreenQr   = document.getElementById('btnFullscreenQr');

  const fullscreenModal    = document.getElementById('fullscreenModal');
  const fullscreenQrCanvas = document.getElementById('fullscreenQrCanvas');
  const fullscreenCodeTxt  = document.getElementById('fullscreenCodeTxt');
  const btnCloseFullscreen = document.getElementById('btnCloseFullscreen');

  // State
  let fullRgba = null;
  let fullW = 0;
  let fullH = 0;
  let currentRoi = null;
  let currentVisionResult = null;
  let origCabinetQrCode = null;
  let manualTiltOverride = null;

  function setProgress(msg) {
    if (!msg) {
      ocrProgressBox.classList.add('workspace-hidden');
      ocrProgressBox.textContent = '';
    } else {
      ocrProgressBox.classList.remove('workspace-hidden');
      ocrProgressBox.textContent = msg;
    }
  }

  // Pre-warm OCR worker in background after UI paints
  window.addEventListener('load', function () {
    if ('serviceWorker' in navigator) {
      navigator.serviceWorker.register('./sw.js').catch(function () {});
    }

    setTimeout(function () {
      BSSOcrQr.getOcrWorker(function (st) {
        engineStatusPill.textContent = st.indexOf('%') >= 0 ? 'Đang nạp OCR...' : 'Khởi tạo...';
      }).then(function () {
        engineStatusPill.textContent = 'Sẵn sàng Offline';
      }).catch(function () {
        engineStatusPill.textContent = 'Chế độ Nhập/QR';
      });
    }, 300);
  });

  // =========================================================================
  // 1. FILE UPLOAD & CLIPBOARD PASTE
  // =========================================================================
  btnPickFile.addEventListener('click', function () {
    fileInput.value = '';
    fileInput.click();
  });

  fileInput.addEventListener('change', function (e) {
    const file = e.target.files && e.target.files[0];
    if (file) loadImageFile(file);
  });

  window.addEventListener('paste', function (e) {
    if (!e.clipboardData || !e.clipboardData.items) return;
    for (let i = 0; i < e.clipboardData.items.length; i++) {
      const it = e.clipboardData.items[i];
      if (it.type && it.type.indexOf('image/') === 0) {
        const blob = it.getAsFile();
        if (blob) loadImageFile(blob);
        break;
      }
    }
  });

  function loadImageFile(fileBlob) {
    setProgress('Đang nạp ảnh vào bộ lọc Kính Đêm...');
    const url = URL.createObjectURL(fileBlob);
    const img = new Image();
    img.onload = function () {
      URL.revokeObjectURL(url);
      const maxDim = 2200;
      let w = img.naturalWidth || img.width;
      let h = img.naturalHeight || img.height;
      if (Math.max(w, h) > maxDim) {
        const ratio = maxDim / Math.max(w, h);
        w = Math.round(w * ratio);
        h = Math.round(h * ratio);
      }
      const c = document.createElement('canvas');
      c.width = w;
      c.height = h;
      c.getContext('2d').drawImage(img, 0, 0, w, h);
      loadCanvasIntoPipeline(c);
    };
    img.onerror = function () {
      URL.revokeObjectURL(url);
      setProgress('Không đọc được định dạng ảnh này.');
    };
    img.src = url;
  }

  // =========================================================================
  // 2. AUTO NIGHT-VISION PIPELINE + OCR
  // =========================================================================
  function loadCanvasIntoPipeline(srcCanv) {
    fullW = srcCanv.width;
    fullH = srcCanv.height;
    fullRgba = srcCanv.getContext('2d').getImageData(0, 0, fullW, fullH).data;

    origCabinetQrCode = BSSOcrQr.tryDecodeOriginalCabinetQr(fullRgba, fullW, fullH);

    manualTiltOverride = null;
    gainSlider.value = '1.05';
    gainVal.textContent = '1.05x';
    currentRoi = BSSVision.autoLocateBssIdRoi(fullRgba, fullW, fullH);

    visionCard.classList.remove('workspace-hidden');
    refreshNightVisionPreview(true);
    runOcrOnCurrentVision();
  }

  function refreshNightVisionPreview(syncTiltSlider) {
    if (!fullRgba || !currentRoi) return;

    const gain = parseFloat(gainSlider.value) || 1.05;
    currentVisionResult = BSSVision.buildNightVisionVariants(fullRgba, fullW, fullH, currentRoi, {
      gain: gain,
      thresholdBias: 0,
      manualTiltDeg: manualTiltOverride
    });

    if (syncTiltSlider) {
      tiltSlider.value = String(currentVisionResult.detectedTiltDeg.toFixed(1));
      tiltVal.textContent = (currentVisionResult.detectedTiltDeg >= 0 ? '+' : '') + currentVisionResult.detectedTiltDeg.toFixed(1) + '°';
    }

    const pv = currentVisionResult.preview;
    nightVisionCanvas.width = pv.width;
    nightVisionCanvas.height = pv.height;
    const nvCtx = nightVisionCanvas.getContext('2d');
    nvCtx.putImageData(new ImageData(new Uint8ClampedArray(pv.rgba), pv.width, pv.height), 0, 0);
  }

  let runCounter = 0;
  async function runOcrOnCurrentVision() {
    if (!currentVisionResult) return;
    const myRun = ++runCounter;
    btnReOcr.disabled = true;

    try {
      const out = await BSSOcrQr.recognizeBssFromVariants(currentVisionResult, function (st) {
        if (myRun === runCounter) setProgress(st);
      });
      if (myRun !== runCounter) return;

      if (out.best && out.best.code) {
        setProgress('');
        applyDetectedCode(out.best.code, 'ocr', true);
      } else if (origCabinetQrCode) {
        setProgress('Dòng chữ đáy quá mờ — Đã cứu hộ từ góc mã QR còn sót trên ảnh!');
        applyDetectedCode(origCabinetQrCode, 'qr-fallback', true);
      } else {
        setProgress('Ảnh hơi mờ nên máy chưa chốt hết số — Hãy nhìn khung "Ảnh Kính Nhìn Đêm" bên trên rồi gõ/sửa vào ô dưới!');
        if (!bssCodeInput.value) {
          bssCodeInput.value = 'BSS-';
        }
        bssCodeInput.focus();
      }
    } catch (err) {
      if (myRun === runCounter) {
        setProgress('Lỗi đọc chữ: ' + (err.message || err) + ' — Vẫn có thể nhìn ảnh Kính Đêm và gõ số vào ô dưới để lấy QR ngay!');
      }
    } finally {
      if (myRun === runCounter) btnReOcr.disabled = false;
    }
  }

  gainSlider.addEventListener('input', function () {
    gainVal.textContent = parseFloat(gainSlider.value).toFixed(2) + 'x';
    refreshNightVisionPreview(false);
  });

  tiltSlider.addEventListener('input', function () {
    manualTiltOverride = parseFloat(tiltSlider.value) || 0;
    tiltVal.textContent = (manualTiltOverride >= 0 ? '+' : '') + manualTiltOverride.toFixed(1) + '°';
    refreshNightVisionPreview(false);
  });

  btnReOcr.addEventListener('click', function () {
    runOcrOnCurrentVision();
  });

  // =========================================================================
  // 3. CODE SANITIZATION & LIVE 1:1 QR GENERATION FOR 2ND PHONE SCANNING
  // =========================================================================
  function applyDetectedCode(rawCode, sourceTag, shouldScroll) {
    const clean = BSSOcrQr.sanitizeUserBssInput(rawCode);
    bssCodeInput.value = clean;
    updateQrFromInput(sourceTag);
    if (shouldScroll && !qrCard.classList.contains('workspace-hidden')) {
      setTimeout(function () {
        qrCard.scrollIntoView({ behavior: 'smooth', block: 'center' });
      }, 80);
    }
  }

  function updateQrFromInput(sourceTag) {
    const clean = BSSOcrQr.sanitizeUserBssInput(bssCodeInput.value);
    crossVerifyBadge.textContent = '';

    if (!clean || clean === 'BSS-') {
      codeValidationMsg.textContent = 'Nhập mã dạng BSS-26012341000635 (hoặc gõ thẳng 14 chữ số)';
      codeValidationMsg.className = 'badge-warn';
      return;
    }

    const m = /^BSS-(\d+)$/.exec(clean);
    if (m) {
      const len = m[1].length;
      if (len === 14) {
        codeValidationMsg.textContent = 'Chuẩn cấu trúc trạm VinFast (BSS- + đủ 14 chữ số, đã lọc bỏ "ID:")';
        codeValidationMsg.className = 'badge-ok';
      } else {
        codeValidationMsg.textContent = 'Đang có ' + len + ' chữ số sau BSS- (tủ VinFast chuẩn có 14 số — hãy liếc ảnh Kính Đêm kiểm tra)';
        codeValidationMsg.className = 'badge-warn';
      }
    } else {
      codeValidationMsg.textContent = 'Đang tạo QR theo chuỗi tùy chỉnh: ' + clean;
      codeValidationMsg.className = 'badge-warn';
    }

    if (origCabinetQrCode && clean === origCabinetQrCode) {
      crossVerifyBadge.textContent = 'Khớp 100% QR gốc';
      crossVerifyBadge.className = 'badge-ok';
    } else if (sourceTag === 'ocr') {
      crossVerifyBadge.textContent = 'Bóc từ chữ xám đáy màn';
      crossVerifyBadge.className = 'badge-ok';
    }

    const ok = BSSOcrQr.renderCrispQrToCanvas(qrCanvas, clean, {
      sizePx: 340,
      quietModules: 4,
      showCornerBrackets: true
    });
    if (ok) {
      qrCard.classList.remove('workspace-hidden');
      qrCodeCaption.textContent = clean;
    }
  }

  bssCodeInput.addEventListener('input', function () {
    updateQrFromInput('manual');
  });

  bssCodeInput.addEventListener('blur', function () {
    const clean = BSSOcrQr.sanitizeUserBssInput(bssCodeInput.value);
    if (clean) bssCodeInput.value = clean;
    updateQrFromInput('manual');
  });

  btnCopyCode.addEventListener('click', function () {
    const clean = BSSOcrQr.sanitizeUserBssInput(bssCodeInput.value);
    if (!clean) return;
    navigator.clipboard.writeText(clean).then(function () {
      const old = btnCopyCode.textContent;
      btnCopyCode.textContent = 'Đã chép!';
      setTimeout(function () { btnCopyCode.textContent = old; }, 1200);
    }).catch(function () {});
  });

  btnFullscreenQr.addEventListener('click', function () {
    const clean = BSSOcrQr.sanitizeUserBssInput(bssCodeInput.value);
    if (!clean) return;
    BSSOcrQr.renderCrispQrToCanvas(fullscreenQrCanvas, clean, {
      sizePx: 420,
      quietModules: 4,
      showCornerBrackets: true
    });
    fullscreenCodeTxt.textContent = clean;
    fullscreenModal.classList.remove('workspace-hidden');
  });

  btnCloseFullscreen.addEventListener('click', function () {
    fullscreenModal.classList.add('workspace-hidden');
  });

  fullscreenModal.addEventListener('click', function (e) {
    if (e.target === fullscreenModal) fullscreenModal.classList.add('workspace-hidden');
  });
})();
