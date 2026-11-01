/**
 * app.js — Interactive Night-Vision BSS QR Rescue Controller
 */
(function () {
  'use strict';

  const STORAGE_KEY = 'vf_bss_saved_stations_v1';

  // DOM Elements
  const btnOpenCam       = document.getElementById('btnOpenCam');
  const btnPickFile      = document.getElementById('btnPickFile');
  const fileInput        = document.getElementById('fileInput');
  const engineStatusPill = document.getElementById('engineStatusPill');

  const cameraPanel      = document.getElementById('cameraPanel');
  const camVideo         = document.getElementById('camVideo');
  const camZoomSlider    = document.getElementById('camZoomSlider');
  const camZoomVal       = document.getElementById('camZoomVal');
  const btnSnapStrip     = document.getElementById('btnSnapStrip');
  const btnTorch         = document.getElementById('btnTorch');
  const btnCloseCam      = document.getElementById('btnCloseCam');

  const visionCard       = document.getElementById('visionCard');
  const sourceCanvas     = document.getElementById('sourceCanvas');
  const btnAutoRoi       = document.getElementById('btnAutoRoi');
  const nightVisionCanvas = document.getElementById('nightVisionCanvas');
  const gainSlider       = document.getElementById('gainSlider');
  const gainVal          = document.getElementById('gainVal');
  const tiltSlider       = document.getElementById('tiltSlider');
  const tiltVal          = document.getElementById('tiltVal');
  const btnReOcr         = document.getElementById('btnReOcr');
  const ocrProgressBox   = document.getElementById('ocrProgressBox');

  const bssCodeInput     = document.getElementById('bssCodeInput');
  const btnCopyCode      = document.getElementById('btnCopyCode');
  const codeValidationMsg = document.getElementById('codeValidationMsg');
  const crossVerifyBadge = document.getElementById('crossVerifyBadge');

  const qrCard           = document.getElementById('qrCard');
  const qrCanvas         = document.getElementById('qrCanvas');
  const qrCodeCaption    = document.getElementById('qrCodeCaption');
  const btnFullscreenQr  = document.getElementById('btnFullscreenQr');
  const btnDownloadQr    = document.getElementById('btnDownloadQr');
  const stationNoteInput = document.getElementById('stationNoteInput');
  const btnSaveStation   = document.getElementById('btnSaveStation');

  const savedStationsList = document.getElementById('savedStationsList');
  const fullscreenModal   = document.getElementById('fullscreenModal');
  const fullscreenQrCanvas = document.getElementById('fullscreenQrCanvas');
  const fullscreenCodeTxt = document.getElementById('fullscreenCodeTxt');
  const btnCloseFullscreen = document.getElementById('btnCloseFullscreen');

  // State
  let fullImgCanvas = null; // Offscreen canvas holding full uploaded/captured photo
  let fullRgba = null;
  let fullW = 0;
  let fullH = 0;
  let currentRoi = null;
  let currentVisionResult = null;
  let origCabinetQrCode = null;
  let manualTiltOverride = null;

  let mediaStream = null;
  let videoTrack = null;
  let torchOn = false;
  let digitalZoom = 1.0;

  // Pointer drag state on sourceCanvas
  let dragMode = null; // 'move' | 'draw'
  let dragStartPt = null;
  let dragStartRoi = null;

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
    renderSavedStations();

    setTimeout(function () {
      BSSOcrQr.getOcrWorker(function (st) {
        engineStatusPill.textContent = st.indexOf('%') >= 0 ? 'Đang nạp OCR...' : 'Khởi tạo...';
      }).then(function () {
        engineStatusPill.textContent = 'Sẵn sàng Offline';
      }).catch(function () {
        engineStatusPill.textContent = 'Chế độ Nhập/QR';
      });
    }, 350);
  });

  // =========================================================================
  // 1. LIVE CAMERA STRIP VIEWFINDER (ANTI-POPUP GLARE)
  // =========================================================================
  async function stopCamera() {
    if (mediaStream) {
      mediaStream.getTracks().forEach(function (t) { t.stop(); });
      mediaStream = null;
      videoTrack = null;
    }
    torchOn = false;
    camVideo.srcObject = null;
    cameraPanel.classList.add('workspace-hidden');
  }

  btnOpenCam.addEventListener('click', async function () {
    if (!mediaStream) {
      try {
        const stream = await navigator.mediaDevices.getUserMedia({
          audio: false,
          video: {
            facingMode: { ideal: 'environment' },
            width: { ideal: 1920 },
            height: { ideal: 1080 }
          }
        });
        mediaStream = stream;
        camVideo.srcObject = stream;
        await camVideo.play();
        videoTrack = stream.getVideoTracks()[0] || null;

        // Apply continuous focus if supported by mobile browser
        if (videoTrack && videoTrack.getCapabilities) {
          const caps = videoTrack.getCapabilities();
          const adv = {};
          if (caps.focusMode && caps.focusMode.indexOf('continuous') >= 0) {
            adv.focusMode = 'continuous';
          }
          if (Object.keys(adv).length) {
            videoTrack.applyConstraints({ advanced: [adv] }).catch(function () {});
          }
          btnTorch.style.display = caps.torch ? 'inline-flex' : 'none';
        }
        cameraPanel.classList.remove('workspace-hidden');
      } catch (err) {
        alert('Không mở được Camera trực tiếp trên trình duyệt này (' + (err.message || err) + '). Hãy bấm nút "Chọn Ảnh Chụp" bên cạnh!');
      }
    } else {
      stopCamera();
    }
  });

  camZoomSlider.addEventListener('input', function () {
    digitalZoom = parseFloat(camZoomSlider.value) || 1.0;
    camZoomVal.textContent = digitalZoom.toFixed(1) + 'x';
    camVideo.style.transform = 'scale(' + digitalZoom + ')';

    // Use hardware zoom too if supported
    if (videoTrack && videoTrack.getCapabilities) {
      const caps = videoTrack.getCapabilities();
      if (caps.zoom) {
        const hwZ = Math.min(caps.zoom.max, Math.max(caps.zoom.min, digitalZoom));
        videoTrack.applyConstraints({ advanced: [{ zoom: hwZ }] }).catch(function () {});
        camVideo.style.transform = 'scale(1)';
      }
    }
  });

  btnTorch.addEventListener('click', function () {
    if (!videoTrack) return;
    torchOn = !torchOn;
    videoTrack.applyConstraints({ advanced: [{ torch: torchOn }] }).catch(function () {
      torchOn = false;
    });
  });

  btnCloseCam.addEventListener('click', stopCamera);

  btnSnapStrip.addEventListener('click', function () {
    if (!camVideo.videoWidth || !camVideo.videoHeight) return;
    const vw = camVideo.videoWidth;
    const vh = camVideo.videoHeight;

    // Extract the central aiming strip (matching .aim-strip-box 88% width x 26% height, accounting for digitalZoom)
    const effZoom = (camVideo.style.transform && camVideo.style.transform.indexOf('scale(1)') < 0) ? digitalZoom : 1.0;
    const visW = vw / effZoom;
    const visH = vh / effZoom;
    const visX = (vw - visW) * 0.5;
    const visY = (vh - visH) * 0.5;

    const cropW = Math.round(visW * 0.88);
    const cropH = Math.round(visH * 0.28);
    const cropX = Math.round(visX + (visW - cropW) * 0.5);
    const cropY = Math.round(visY + (visH - cropH) * 0.5);

    const snap = document.createElement('canvas');
    snap.width = cropW;
    snap.height = cropH;
    snap.getContext('2d').drawImage(camVideo, cropX, cropY, cropW, cropH, 0, 0, cropW, cropH);

    stopCamera();
    loadCanvasIntoPipeline(snap);
  });

  // =========================================================================
  // 2. FILE UPLOAD & CLIPBOARD PASTE
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
    stopCamera();
    setProgress('Đang nạp ảnh vào bộ lọc Kính Đêm...');
    const url = URL.createObjectURL(fileBlob);
    const img = new Image();
    img.onload = function () {
      URL.revokeObjectURL(url);
      // Cap ultra-huge 12MP photos to max 2200px longest side so canvas processing stays < 25ms on iPhone 8
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
  // 3. NIGHT-VISION PIPELINE + INTERACTIVE CROP + OCR
  // =========================================================================
  function loadCanvasIntoPipeline(srcCanv) {
    fullImgCanvas = srcCanv;
    fullW = srcCanv.width;
    fullH = srcCanv.height;
    fullRgba = srcCanv.getContext('2d').getImageData(0, 0, fullW, fullH).data;

    // Optional background check if unblocked original QR exists in wide shot
    origCabinetQrCode = BSSOcrQr.tryDecodeOriginalCabinetQr(fullRgba, fullW, fullH);

    // Auto-locate bottom grey ID strip
    manualTiltOverride = null;
    gainSlider.value = '1.05';
    gainVal.textContent = '1.05x';
    currentRoi = BSSVision.autoLocateBssIdRoi(fullRgba, fullW, fullH);

    visionCard.classList.remove('workspace-hidden');
    refreshNightVisionPreview(true);
    runOcrOnCurrentVision();
  }

  function drawSourceWithRoiOverlay() {
    if (!fullImgCanvas || !currentRoi) return;
    sourceCanvas.width = fullW;
    sourceCanvas.height = fullH;
    const ctx = sourceCanvas.getContext('2d');
    ctx.drawImage(fullImgCanvas, 0, 0);

    // Dim area outside ROI slightly so the selected ID strip stands out clearly
    ctx.fillStyle = 'rgba(2, 6, 23, 0.48)';
    ctx.fillRect(0, 0, fullW, currentRoi.y);
    ctx.fillRect(0, currentRoi.y + currentRoi.h, fullW, fullH - (currentRoi.y + currentRoi.h));
    ctx.fillRect(0, currentRoi.y, currentRoi.x, currentRoi.h);
    ctx.fillRect(currentRoi.x + currentRoi.w, currentRoi.y, fullW - (currentRoi.x + currentRoi.w), currentRoi.h);

    // Emerald frame around ROI
    ctx.strokeStyle = '#10b981';
    ctx.lineWidth = Math.max(2, Math.round(fullW * 0.004));
    ctx.strokeRect(currentRoi.x, currentRoi.y, currentRoi.w, currentRoi.h);
  }

  function refreshNightVisionPreview(syncTiltSlider) {
    if (!fullRgba || !currentRoi) return;
    drawSourceWithRoiOverlay();

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
        applyDetectedCode(out.best.code, 'ocr');
      } else if (origCabinetQrCode) {
        setProgress('Dòng chữ đáy quá mờ — Đã cứu hộ từ góc mã QR còn sót trên ảnh!');
        applyDetectedCode(origCabinetQrCode, 'qr-fallback');
      } else {
        setProgress('Ảnh hơi mờ nên máy chưa chốt hết số — Hãy nhìn khung "Kính Nhìn Đêm" bên trên rồi gõ/sửa vào ô dưới (hoặc kéo khung xanh trùm đúng dòng chữ)!');
        if (!bssCodeInput.value) {
          bssCodeInput.value = 'BSS-';
        }
        bssCodeInput.focus();
      }
    } catch (err) {
      if (myRun === runCounter) {
        setProgress('Lỗi đọc chữ: ' + (err.message || err) + ' — Bạn vẫn có thể nhìn ảnh Kính Đêm và gõ số vào ô dưới để lấy QR ngay!');
      }
    } finally {
      if (myRun === runCounter) btnReOcr.disabled = false;
    }
  }

  // Interactive Pointer Drag / Draw on sourceCanvas
  function canvasCoordsFromEvent(e) {
    const rect = sourceCanvas.getBoundingClientRect();
    const scaleX = fullW / Math.max(1, rect.width);
    const scaleY = fullH / Math.max(1, rect.height);
    return {
      x: Math.max(0, Math.min(fullW - 1, (e.clientX - rect.left) * scaleX)),
      y: Math.max(0, Math.min(fullH - 1, (e.clientY - rect.top) * scaleY))
    };
  }

  sourceCanvas.addEventListener('pointerdown', function (e) {
    if (!fullRgba || !currentRoi) return;
    sourceCanvas.setPointerCapture(e.pointerId);
    const pt = canvasCoordsFromEvent(e);
    dragStartPt = pt;
    dragStartRoi = Object.assign({}, currentRoi);

    const inside = (
      pt.x >= currentRoi.x && pt.x <= currentRoi.x + currentRoi.w &&
      pt.y >= currentRoi.y && pt.y <= currentRoi.y + currentRoi.h
    );
    dragMode = inside ? 'move' : 'draw';
  });

  sourceCanvas.addEventListener('pointermove', function (e) {
    if (!dragMode || !dragStartPt || !fullRgba) return;
    const pt = canvasCoordsFromEvent(e);
    if (dragMode === 'move') {
      const dx = pt.x - dragStartPt.x;
      const dy = pt.y - dragStartPt.y;
      currentRoi = {
        x: Math.max(0, Math.min(fullW - dragStartRoi.w, Math.round(dragStartRoi.x + dx))),
        y: Math.max(0, Math.min(fullH - dragStartRoi.h, Math.round(dragStartRoi.y + dy))),
        w: dragStartRoi.w,
        h: dragStartRoi.h,
        mode: 'manual-move'
      };
    } else {
      const x0 = Math.min(dragStartPt.x, pt.x);
      const y0 = Math.min(dragStartPt.y, pt.y);
      const w = Math.max(24, Math.abs(pt.x - dragStartPt.x));
      const h = Math.max(16, Math.abs(pt.y - dragStartPt.y));
      currentRoi = {
        x: Math.round(x0),
        y: Math.round(y0),
        w: Math.min(fullW - Math.round(x0), Math.round(w)),
        h: Math.min(fullH - Math.round(y0), Math.round(h)),
        mode: 'manual-draw'
      };
    }
    manualTiltOverride = null;
    refreshNightVisionPreview(true);
  });

  sourceCanvas.addEventListener('pointerup', function () {
    if (!dragMode) return;
    dragMode = null;
    runOcrOnCurrentVision();
  });

  btnAutoRoi.addEventListener('click', function () {
    if (!fullRgba) return;
    manualTiltOverride = null;
    currentRoi = BSSVision.autoLocateBssIdRoi(fullRgba, fullW, fullH);
    refreshNightVisionPreview(true);
    runOcrOnCurrentVision();
  });

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
  // 4. CODE SANITIZATION & LIVE 1:1 QR GENERATION
  // =========================================================================
  function applyDetectedCode(rawCode, sourceTag) {
    const clean = BSSOcrQr.sanitizeUserBssInput(rawCode);
    bssCodeInput.value = clean;
    updateQrFromInput(sourceTag);
  }

  function updateQrFromInput(sourceTag) {
    const clean = BSSOcrQr.sanitizeUserBssInput(bssCodeInput.value);
    crossVerifyBadge.textContent = '';

    if (!clean || clean === 'BSS-') {
      codeValidationMsg.textContent = 'Nhập mã dạng BSS-26063041024325 (hoặc gõ thẳng 14 chữ số)';
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
        codeValidationMsg.textContent = 'Đang có ' + len + ' chữ số sau BSS- (thường tủ VinFast có 14 số — hãy liếc ảnh Kính Đêm kiểm tra)';
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
      sizePx: 300,
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

  // Fullscreen & Download / iOS Share
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

  btnDownloadQr.addEventListener('click', function () {
    const clean = BSSOcrQr.sanitizeUserBssInput(bssCodeInput.value);
    if (!clean) return;
    const cardCanvas = BSSOcrQr.buildDownloadableQrCardCanvas(clean, stationNoteInput.value);

    cardCanvas.toBlob(async function (blob) {
      if (!blob) return;
      const fileName = clean + '.png';
      // On Safari iPhone, Web Share API with files allows 1-tap "Save Image" straight into iOS Photos!
      if (navigator.canShare && typeof File === 'function') {
        const file = new File([blob], fileName, { type: 'image/png' });
        if (navigator.canShare({ files: [file] })) {
          try {
            await navigator.share({
              title: 'QR Đổi Pin ' + clean,
              files: [file]
            });
            return;
          } catch (err) {
            if (err && err.name === 'AbortError') return;
          }
        }
      }
      // Standard download fallback
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = fileName;
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      setTimeout(function () { URL.revokeObjectURL(url); }, 2000);
    }, 'image/png');
  });

  // =========================================================================
  // 5. SAVED DEAD-TOUCH STATIONS DIRECTORY (LOCALSTORAGE)
  // =========================================================================
  function loadSavedList() {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      const arr = raw ? JSON.parse(raw) : [];
      return Array.isArray(arr) ? arr : [];
    } catch (_) {
      return [];
    }
  }

  function saveListToDisk(arr) {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(arr));
    } catch (_) {}
  }

  function renderSavedStations() {
    const list = loadSavedList();
    savedStationsList.innerHTML = '';
    if (!list.length) {
      const empty = document.createElement('div');
      empty.style.fontSize = '0.8rem';
      empty.style.color = '#64748b';
      empty.textContent = 'Chưa có trạm nào được lưu. Khi quét được mã một tủ liệt cảm ứng, lưu tên trạm lại để lần sau bấm 1 phát ra QR ngay!';
      savedStationsList.appendChild(empty);
      return;
    }

    list.forEach(function (item, idx) {
      const row = document.createElement('div');
      row.className = 'station-item';

      const info = document.createElement('div');
      info.className = 'station-info';
      const nm = document.createElement('div');
      nm.className = 'station-name';
      nm.textContent = item.note || ('Trạm đổi pin #' + (idx + 1));
      const cd = document.createElement('div');
      cd.className = 'station-code';
      cd.textContent = item.code;
      info.appendChild(nm);
      info.appendChild(cd);

      info.addEventListener('click', function () {
        stationNoteInput.value = item.note || '';
        applyDetectedCode(item.code, 'saved');
        qrCard.scrollIntoView({ behavior: 'smooth', block: 'center' });
      });

      const del = document.createElement('button');
      del.className = 'btn-del';
      del.type = 'button';
      del.textContent = 'Xóa';
      del.addEventListener('click', function () {
        const next = loadSavedList().filter(function (_, i) { return i !== idx; });
        saveListToDisk(next);
        renderSavedStations();
      });

      row.appendChild(info);
      row.appendChild(del);
      savedStationsList.appendChild(row);
    });
  }

  btnSaveStation.addEventListener('click', function () {
    const clean = BSSOcrQr.sanitizeUserBssInput(bssCodeInput.value);
    if (!clean || clean === 'BSS-') return;
    const note = (stationNoteInput.value || '').trim() || ('Tủ liệt màn (' + new Date().toLocaleDateString('vi-VN') + ')');
    const list = loadSavedList().filter(function (x) { return x.code !== clean; });
    list.unshift({ code: clean, note: note, savedAt: Date.now() });
    saveListToDisk(list.slice(0, 50));
    renderSavedStations();
    const old = btnSaveStation.textContent;
    btnSaveStation.textContent = 'Đã lưu!';
    setTimeout(function () { btnSaveStation.textContent = old; }, 1200);
  });
})();
