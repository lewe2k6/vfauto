(function () {
  'use strict';

  // =========================================================================
  // 1. 60 TIỂU VÙNG KHÍ TƯỢNG THỰC TẾ TOÀN HÀ NỘI (NỘI THÀNH + NGOẠI THÀNH)
  // =========================================================================
  var HANOI_ZONES = [
    // --- HOÀN KIẾM (3) ---
    { id: 'hk_hoguom', name: 'Hồ Gươm - Phố Cổ', district: 'Hoàn Kiếm', lat: 21.0285, lng: 105.8542, urban: 1 },
    { id: 'hk_cuanam', name: 'Cửa Nam - Ga HN', district: 'Hoàn Kiếm', lat: 21.0242, lng: 105.8415, urban: 1 },
    { id: 'hk_chuongduong', name: 'Chương Dương Độ', district: 'Hoàn Kiếm', lat: 21.0318, lng: 105.8612, urban: 1 },

    // --- BA ĐÌNH (3) ---
    { id: 'bd_langbac', name: 'Lăng Bác - Đội Cấn', district: 'Ba Đình', lat: 21.0368, lng: 105.8346, urban: 1 },
    { id: 'bd_kimma', name: 'Kim Mã - Liễu Giai', district: 'Ba Đình', lat: 21.0315, lng: 105.8142, urban: 1 },
    { id: 'bd_yenphu', name: 'Yên Phụ - Tân Ấp', district: 'Ba Đình', lat: 21.0465, lng: 105.8458, urban: 1 },

    // --- ĐỐNG ĐA (4) ---
    { id: 'dd_ngatuso', name: 'Ngã Tư Sở - Láng', district: 'Đống Đa', lat: 21.0038, lng: 105.8206, urban: 1 },
    { id: 'dd_thaiha', name: 'Thái Hà - Chùa Bộc', district: 'Đống Đa', lat: 21.0102, lng: 105.8265, urban: 1 },
    { id: 'dd_ochodua', name: 'Ô Chợ Dừa - Xã Đàn', district: 'Đống Đa', lat: 21.0182, lng: 105.8295, urban: 1 },
    { id: 'dd_vanmieu', name: 'Văn Miếu - T.Đ.Thắng', district: 'Đống Đa', lat: 21.0258, lng: 105.8335, urban: 1 },

    // --- HAI BÀ TRƯNG (3) ---
    { id: 'hbt_bachkhoa', name: 'Bách Khoa - Giải Phóng', district: 'Hai Bà Trưng', lat: 21.0045, lng: 105.8438, urban: 1 },
    { id: 'hbt_phohue', name: 'Phố Huế - Bà Triệu', district: 'Hai Bà Trưng', lat: 21.0145, lng: 105.8512, urban: 1 },
    { id: 'hbt_timescity', name: 'Minh Khai - Times City', district: 'Hai Bà Trưng', lat: 20.9958, lng: 105.8675, urban: 1 },

    // --- CẦU GIẤY (3) ---
    { id: 'cg_xuanthuy', name: 'Xuân Thủy - Dịch Vọng', district: 'Cầu Giấy', lat: 21.0368, lng: 105.7895, urban: 1 },
    { id: 'cg_trunghoa', name: 'Trung Hòa - T.D.Hưng', district: 'Cầu Giấy', lat: 21.0095, lng: 105.7988, urban: 1 },
    { id: 'cg_hqviet', name: 'Hoàng Quốc Việt', district: 'Cầu Giấy', lat: 21.0462, lng: 105.7965, urban: 1 },

    // --- THANH XUÂN (3) ---
    { id: 'tx_nguyentrai', name: 'Nguyễn Trãi - Thượng Đình', district: 'Thanh Xuân', lat: 20.9965, lng: 105.8095, urban: 1 },
    { id: 'tx_khuatduytien', name: 'Khuất Duy Tiến', district: 'Thanh Xuân', lat: 20.9935, lng: 105.7985, urban: 1 },
    { id: 'tx_levanluong', name: 'Lê Văn Lương - Nhân Chính', district: 'Thanh Xuân', lat: 21.0032, lng: 105.8045, urban: 1 },

    // --- HOÀNG MAI (3) ---
    { id: 'hm_linhdam', name: 'Linh Đàm - Giải Phóng', district: 'Hoàng Mai', lat: 20.9675, lng: 105.8295, urban: 1 },
    { id: 'hm_denlu', name: 'Đền Lừ - Tân Mai', district: 'Hoàng Mai', lat: 20.9852, lng: 105.8568, urban: 1 },
    { id: 'hm_yenso', name: 'Yên Sở - Pháp Vân', district: 'Hoàng Mai', lat: 20.9612, lng: 105.8585, urban: 1 },

    // --- TÂY HỒ (3) ---
    { id: 'th_quangan', name: 'Quảng An - Phủ Tây Hồ', district: 'Tây Hồ', lat: 21.0645, lng: 105.8235, urban: 1 },
    { id: 'th_vochicong', name: 'Xuân La - Võ Chí Công', district: 'Tây Hồ', lat: 21.0695, lng: 105.8065, urban: 1 },
    { id: 'th_phuthuong', name: 'Phú Thượng - Nhật Tân', district: 'Tây Hồ', lat: 21.0845, lng: 105.8145, urban: 1 },

    // --- LONG BIÊN (4) ---
    { id: 'lb_bode', name: 'Bồ Đề - Nguyễn Văn Cừ', district: 'Long Biên', lat: 21.0435, lng: 105.8755, urban: 1 },
    { id: 'lb_saidong', name: 'Sài Đồng - Riverside', district: 'Long Biên', lat: 21.0412, lng: 105.9145, urban: 1 },
    { id: 'lb_ngocthuy', name: 'Ngọc Thụy - Khai Sơn', district: 'Long Biên', lat: 21.0595, lng: 105.8695, urban: 1 },
    { id: 'lb_colinh', name: 'Thạch Bàn - Cổ Linh', district: 'Long Biên', lat: 21.0215, lng: 105.9015, urban: 1 },

    // --- NAM TỪ LIÊM (4) ---
    { id: 'ntl_mydinh', name: 'Mỹ Đình - Sân VĐ', district: 'Nam Từ Liêm', lat: 21.0205, lng: 105.7665, urban: 1 },
    { id: 'ntl_keangnam', name: 'Mễ Trì - Keangnam', district: 'Nam Từ Liêm', lat: 21.0165, lng: 105.7838, urban: 1 },
    { id: 'ntl_smartcity', name: 'Tây Mỗ - Smart City', district: 'Nam Từ Liêm', lat: 21.0035, lng: 105.7415, urban: 1 },
    { id: 'ntl_daimo', name: 'Đại Mỗ - Tố Hữu', district: 'Nam Từ Liêm', lat: 20.9865, lng: 105.7645, urban: 1 },

    // --- BẮC TỪ LIÊM (3) ---
    { id: 'btl_conhue', name: 'Cổ Nhuế - P.V.Đồng', district: 'Bắc Từ Liêm', lat: 21.0585, lng: 105.7812, urban: 1 },
    { id: 'btl_ngoaigiaodoan', name: 'Xuân Đỉnh - N.G.Đoàn', district: 'Bắc Từ Liêm', lat: 21.0692, lng: 105.7945, urban: 1 },
    { id: 'btl_nhon', name: 'Minh Khai - Nhổn', district: 'Bắc Từ Liêm', lat: 21.0545, lng: 105.7365, urban: 1 },

    // --- HÀ ĐÔNG (4) ---
    { id: 'hd_molao', name: 'Mỗ Lao - Văn Quán', district: 'Hà Đông', lat: 20.9795, lng: 105.7865, urban: 1 },
    { id: 'hd_quangtrung', name: 'Quang Trung - Hà Cầu', district: 'Hà Đông', lat: 20.9685, lng: 105.7715, urban: 1 },
    { id: 'hd_aeon', name: 'Dương Nội - Aeon Mall', district: 'Hà Đông', lat: 20.9895, lng: 105.7515, urban: 1 },
    { id: 'hd_yennghia', name: 'Bến Xe Yên Nghĩa', district: 'Hà Đông', lat: 20.9505, lng: 105.7445, urban: 1 },

    // --- 20 TIỂU VÙNG CỬA NGÕ & NGOẠI THÀNH HÀ NỘI ---
    { id: 'gl_oceanpark', name: 'Trâu Quỳ - Ocean Park', district: 'Gia Lâm', lat: 21.0005, lng: 105.9395, urban: 0 },
    { id: 'gl_ninhhiep', name: 'Ninh Hiệp - Yên Viên', district: 'Gia Lâm', lat: 21.0815, lng: 105.9315, urban: 0 },
    { id: 'da_trungtam', name: 'Thị Trấn Đông Anh', district: 'Đông Anh', lat: 21.1385, lng: 105.8485, urban: 0 },
    { id: 'da_vinhngoc', name: 'Vĩnh Ngọc - Bắc Nhật Tân', district: 'Đông Anh', lat: 21.1045, lng: 105.8245, urban: 0 },
    { id: 'tt_vandien', name: 'Văn Điển - Tứ Hiệp', district: 'Thanh Trì', lat: 20.9445, lng: 105.8455, urban: 0 },
    { id: 'tt_ngoc_hoi', name: 'Ngọc Hồi - Cầu Bươu', district: 'Thanh Trì', lat: 20.9285, lng: 105.8395, urban: 0 },
    { id: 'hoaiduc_ankhanh', name: 'An Khánh - Bảo Sơn', district: 'Hoài Đức', lat: 21.0015, lng: 105.7185, urban: 0 },
    { id: 'hoaiduc_tramtroi', name: 'Trạm Trôi - QL32', district: 'Hoài Đức', lat: 21.0665, lng: 105.7045, urban: 0 },
    { id: 'ss_noibai', name: 'Sân Bay Nội Bài', district: 'Sóc Sơn', lat: 21.2187, lng: 105.8042, urban: 0 },
    { id: 'ss_trungtam', name: 'Thị Trấn Sóc Sơn', district: 'Sóc Sơn', lat: 21.2575, lng: 105.8485, urban: 0 },
    { id: 'ml_melinh', name: 'Mê Linh - Tiền Phong', district: 'Mê Linh', lat: 21.1645, lng: 105.7615, urban: 0 },
    { id: 'dp_phung', name: 'Thị Trấn Phùng', district: 'Đan Phượng', lat: 21.0885, lng: 105.6615, urban: 0 },
    { id: 'tthat_hoalac', name: 'Khu CNC Hòa Lạc', district: 'Thạch Thất', lat: 21.0125, lng: 105.5265, urban: 0 },
    { id: 'qo_quocoai', name: 'Thị Trấn Quốc Oai', district: 'Quốc Oai', lat: 20.9905, lng: 105.6415, urban: 0 },
    { id: 'cm_chucson', name: 'Chúc Sơn - Chương Mỹ', district: 'Chương Mỹ', lat: 20.9185, lng: 105.7025, urban: 0 },
    { id: 'to_khuongha', name: 'Bích Hòa - Thanh Oai', district: 'Thanh Oai', lat: 20.8925, lng: 105.7695, urban: 0 },
    { id: 'ttin_thuongtin', name: 'Thị Trấn Thường Tín', district: 'Thường Tín', lat: 20.8705, lng: 105.8625, urban: 0 },
    { id: 'st_sontay', name: 'Thị Xã Sơn Tây', district: 'Sơn Tây', lat: 21.1395, lng: 105.5045, urban: 0 },
    { id: 'bv_bavi', name: 'Tây Đằng - Ba Vì', district: 'Ba Vì', lat: 21.1985, lng: 105.4245, urban: 0 },
    { id: 'px_phuxuyen', name: 'Thị Trấn Phú Xuyên', district: 'Phú Xuyên', lat: 20.7385, lng: 105.9135, urban: 0 }
  ];

  // =========================================================================
  // 2. 45 "ĐIỂM ĐEN NGẬP ÚNG" KINH ĐIỂN TẠI HÀ NỘI
  //    thresholdMm: lượng mưa (mm/h) bắt đầu gây đọng nước / ngập thực tế
  // =========================================================================
  var HANOI_FLOOD_HOTSPOTS = [
    { id: 'fl_1', name: 'Thái Hà - Chùa Bộc (Ngã tư)', district: 'Đống Đa', lat: 21.0098, lng: 105.8248, thresholdMm: 12, depthCm: '25-40cm', bypass: 'Né sang cầu vượt Chùa Bộc hoặc vòng Hoàng Cầu - Xã Đàn' },
    { id: 'fl_2', name: 'Nguyễn Xiển (Hạ Đình - Ngõ 214)', district: 'Thanh Xuân', lat: 20.9845, lng: 105.8065, thresholdMm: 10, depthCm: '30-50cm', bypass: 'Đi đường Vũ Trọng Khánh - Nguyễn Trãi hoặc lên Vành đai 3 trên cao (ô tô)' },
    { id: 'fl_3', name: 'Triều Khúc - Ngõ 68 Nguyễn Xiển', district: 'Thanh Xuân', lat: 20.9808, lng: 105.8012, thresholdMm: 10, depthCm: '30-45cm', bypass: 'Vòng qua Nguyễn Trãi - Chiến Thắng (Văn Quán)' },
    { id: 'fl_4', name: 'Tố Hữu - Lương Thế Vinh', district: 'Nam Từ Liêm', lat: 20.9922, lng: 105.7862, thresholdMm: 12, depthCm: '25-45cm', bypass: 'Vòng sang Lê Văn Lương - Nguyễn Tuân hoặc Đại lộ Thăng Long' },
    { id: 'fl_5', name: 'Tố Hữu - Trung Văn (Cổng C37)', district: 'Nam Từ Liêm', lat: 20.9958, lng: 105.7918, thresholdMm: 13, depthCm: '20-35cm', bypass: 'Rẽ Đỗ Đức Dục - Miếu Đầm ra Đại lộ Thăng Long' },
    { id: 'fl_6', name: 'Dương Đình Nghệ - Keangnam', district: 'Cầu Giấy', lat: 21.0185, lng: 105.7842, thresholdMm: 11, depthCm: '30-50cm', bypass: 'Né ngã tư Keangnam, đi Tôn Thất Thuyết - Trần Thái Tông' },
    { id: 'fl_7', name: 'Phan Văn Trường - Chợ Nhà Xanh', district: 'Cầu Giấy', lat: 21.0382, lng: 105.7852, thresholdMm: 10, depthCm: '25-40cm', bypass: 'Đi thẳng Xuân Thủy - Trần Quốc Hoàn' },
    { id: 'fl_8', name: 'Hoa Bằng - Yên Hòa', district: 'Cầu Giấy', lat: 21.0252, lng: 105.7955, thresholdMm: 11, depthCm: '25-40cm', bypass: 'Đi đường Láng hoặc Trung Kính lớn' },
    { id: 'fl_9', name: 'Vũ Trọng Phụng - Quan Nhân', district: 'Thanh Xuân', lat: 21.0012, lng: 105.8082, thresholdMm: 11, depthCm: '25-40cm', bypass: 'Đi Nguyễn Trãi - Khuất Duy Tiến' },
    { id: 'fl_10', name: 'Nguyễn Tuân - Ngụy Như Kon Tum', district: 'Thanh Xuân', lat: 20.9988, lng: 105.8022, thresholdMm: 12, depthCm: '20-35cm', bypass: 'Đi Lê Văn Lương - Hoàng Đạo Thúy' },
    { id: 'fl_11', name: 'Vương Thừa Vũ - Hoàng Văn Thái', district: 'Thanh Xuân', lat: 20.9982, lng: 105.8218, thresholdMm: 12, depthCm: '25-40cm', bypass: 'Đi Trường Chinh - Lê Trọng Tấn' },
    { id: 'fl_12', name: 'Nguyễn Khuyến - Quốc Tử Giám', district: 'Đống Đa', lat: 21.0282, lng: 105.8365, thresholdMm: 12, depthCm: '25-40cm', bypass: 'Đi Tôn Đức Thắng - Cát Linh' },
    { id: 'fl_13', name: 'Tông Đản - Đinh Lễ (Phố Cổ)', district: 'Hoàn Kiếm', lat: 21.0268, lng: 105.8562, thresholdMm: 15, depthCm: '20-35cm', bypass: 'Đi Trần Quang Khải - Lý Thái Tổ' },
    { id: 'fl_14', name: 'Phùng Hưng - Bát Đàn', district: 'Hoàn Kiếm', lat: 21.0338, lng: 105.8462, thresholdMm: 14, depthCm: '20-35cm', bypass: 'Đi Lý Nam Đế - Trần Phú' },
    { id: 'fl_15', name: 'Liên Trì - Nguyễn Gia Thiều', district: 'Hoàn Kiếm', lat: 21.0202, lng: 105.8465, thresholdMm: 14, depthCm: '20-35cm', bypass: 'Đi Trần Hưng Đạo - Bà Triệu' },
    { id: 'fl_16', name: 'Đội Cấn - Chùa Bát Tháp', district: 'Ba Đình', lat: 21.0352, lng: 105.8212, thresholdMm: 12, depthCm: '25-40cm', bypass: 'Đi Kim Mã - Vạn Bảo' },
    { id: 'fl_17', name: 'Ngọc Khánh - Giảng Võ', district: 'Ba Đình', lat: 21.0282, lng: 105.8175, thresholdMm: 14, depthCm: '20-30cm', bypass: 'Đi Kim Mã - Nguyễn Chí Thanh' },
    { id: 'fl_18', name: 'Trường Chinh - Tôn Thất Tùng', district: 'Đống Đa', lat: 21.0018, lng: 105.8312, thresholdMm: 14, depthCm: '20-35cm', bypass: 'Đi Phạm Ngọc Thạch - Chùa Bộc' },
    { id: 'fl_19', name: 'Minh Khai - Chân Cầu Vĩnh Tuy', district: 'Hai Bà Trưng', lat: 20.9978, lng: 105.8705, thresholdMm: 12, depthCm: '25-40cm', bypass: 'Đi Kim Ngưu - Tam Trinh hoặc đường trên cao Minh Khai' },
    { id: 'fl_20', name: 'Nguyễn Khoái - Dốc Minh Khai', district: 'Hai Bà Trưng', lat: 21.0012, lng: 105.8742, thresholdMm: 13, depthCm: '25-35cm', bypass: 'Đi Trần Khát Chân - Kim Ngưu' },
    { id: 'fl_21', name: 'Giải Phóng - Thịnh Liệt (BX Giáp Bát)', district: 'Hoàng Mai', lat: 20.9768, lng: 105.8415, thresholdMm: 12, depthCm: '25-45cm', bypass: 'Đi Kim Đồng - Tân Mai - Tam Trinh' },
    { id: 'fl_22', name: 'Linh Đàm - Nguyễn Hữu Thọ', district: 'Hoàng Mai', lat: 20.9682, lng: 105.8318, thresholdMm: 12, depthCm: '25-40cm', bypass: 'Đi Nghiêm Xuân Yêm - Giải Phóng' },
    { id: 'fl_23', name: 'Trương Định - Tân Mai', district: 'Hoàng Mai', lat: 20.9845, lng: 105.8492, thresholdMm: 13, depthCm: '20-35cm', bypass: 'Đi trục lớn Tân Mai đôi - Kim Đồng' },
    { id: 'fl_24', name: 'Tam Trinh - Chợ Mai Động', district: 'Hoàng Mai', lat: 20.9885, lng: 105.8628, thresholdMm: 12, depthCm: '25-40cm', bypass: 'Đi Lĩnh Nam hoặc Kim Ngưu' },
    { id: 'fl_25', name: 'Võ Chí Công - Tòa UDIC / Lotte Tây Hồ', district: 'Tây Hồ', lat: 21.0732, lng: 105.8085, thresholdMm: 11, depthCm: '30-50cm', bypass: 'Đi Lạc Long Quân - Âu Cơ' },
    { id: 'fl_26', name: 'Thụy Khuê (Đoạn trường Chu Văn An)', district: 'Tây Hồ', lat: 21.0435, lng: 105.8295, thresholdMm: 12, depthCm: '25-40cm', bypass: 'Đi đường ven Hồ Tây (Trích Sài / Nguyễn Đình Thi)' },
    { id: 'fl_27', name: 'Phạm Văn Đồng - Ecohome / Chân cầu TL', district: 'Bắc Từ Liêm', lat: 21.0785, lng: 105.7858, thresholdMm: 11, depthCm: '30-45cm', bypass: 'Đi Nguyễn Hoàng Tôn - Võ Chí Công' },
    { id: 'fl_28', name: 'Kẻ Vẽ - Đông Ngạc', district: 'Bắc Từ Liêm', lat: 21.0842, lng: 105.7805, thresholdMm: 12, depthCm: '25-40cm', bypass: 'Đi trục Phạm Văn Đồng - Tân Xuân' },
    { id: 'fl_29', name: 'Cổ Nhuế - Ngõ 43 / Đường Tàu', district: 'Bắc Từ Liêm', lat: 21.0615, lng: 105.7765, thresholdMm: 10, depthCm: '30-50cm', bypass: 'Đi Trần Cung hoặc Hoàng Quốc Việt' },
    { id: 'fl_30', name: 'Hầm Chui Số 3 Đại Lộ Thăng Long', district: 'Nam Từ Liêm', lat: 21.0038, lng: 105.7485, thresholdMm: 10, depthCm: '35-60cm', bypass: 'Tuyệt đối không chui hầm khi mưa to, đi cầu vượt Tây Mỗ / đường gom trên' },
    { id: 'fl_31', name: 'Hầm Chui Số 5 & 6 Đại Lộ Thăng Long (Bảo Sơn)', district: 'Hoài Đức', lat: 21.0022, lng: 105.7215, thresholdMm: 9, depthCm: '40-70cm', bypass: 'Rốn ngập sâu bậc nhất phía Tây, đi cầu vượt An Khánh' },
    { id: 'fl_32', name: 'Lê Trọng Tấn - Geleximco Khu A', district: 'Hoài Đức', lat: 20.9992, lng: 105.7285, thresholdMm: 10, depthCm: '35-60cm', bypass: 'Né đoạn Geleximco Khu A, đi trục Smart City hoặc Tỉnh lộ 70' },
    { id: 'fl_33', name: 'Đỗ Đức Dục - Cổng KS Marriott', district: 'Nam Từ Liêm', lat: 21.0068, lng: 105.7818, thresholdMm: 12, depthCm: '25-40cm', bypass: 'Đi Phạm Hùng - Mễ Trì' },
    { id: 'fl_34', name: 'Mỹ Đình - Lê Đức Thọ (Cổng SVĐ)', district: 'Nam Từ Liêm', lat: 21.0218, lng: 105.7652, thresholdMm: 13, depthCm: '25-35cm', bypass: 'Đi Nguyễn Cơ Thạch - Hàm Nghi' },
    { id: 'fl_35', name: 'Châu Văn Liêm - Phú Đô', district: 'Nam Từ Liêm', lat: 21.0092, lng: 105.7645, thresholdMm: 12, depthCm: '25-40cm', bypass: 'Đi Lê Quang Đạo' },
    { id: 'fl_36', name: 'Triều Khúc - Tân Triều (Cầu Bươu)', district: 'Thanh Trì', lat: 20.9625, lng: 105.7985, thresholdMm: 11, depthCm: '30-45cm', bypass: 'Đi Xa La - Nguyễn Xiển' },
    { id: 'fl_37', name: 'Quang Trung - Ga La Khê (Hà Đông)', district: 'Hà Đông', lat: 20.9648, lng: 105.7625, thresholdMm: 11, depthCm: '30-45cm', bypass: 'Đi Lê Trọng Tấn - Văn Phú' },
    { id: 'fl_38', name: 'Yên Nghĩa - Quốc Lộ 6 (Bến Xe)', district: 'Hà Đông', lat: 20.9512, lng: 105.7458, thresholdMm: 11, depthCm: '30-50cm', bypass: 'Đi trục Tố Hữu kéo dài - Đê Yên Nghĩa' },
    { id: 'fl_39', name: 'Chiến Thắng - Văn Quán', district: 'Hà Đông', lat: 20.9785, lng: 105.7925, thresholdMm: 12, depthCm: '25-40cm', bypass: 'Đi trục đôi Nguyễn Khuyến (Văn Quán) - Trần Phú' },
    { id: 'fl_40', name: 'Cổ Linh - Chân Cầu Vĩnh Tuy (Aeon LB)', district: 'Long Biên', lat: 21.0245, lng: 105.8965, thresholdMm: 12, depthCm: '25-40cm', bypass: 'Đi Đàm Quang Trung - Chu Huy Mân' },
    { id: 'fl_41', name: 'Ngọc Lâm - Nguyễn Văn Cừ (Chui cầu LB)', district: 'Long Biên', lat: 21.0448, lng: 105.8692, thresholdMm: 12, depthCm: '25-40cm', bypass: 'Đi đường đê Long Biên - Xuân Quan' },
    { id: 'fl_42', name: 'Đức Giang - Ngô Gia Tự', district: 'Long Biên', lat: 21.0642, lng: 105.8945, thresholdMm: 13, depthCm: '20-35cm', bypass: 'Đi Việt Hưng - Đoàn Khuê' },
    { id: 'fl_43', name: 'Quốc Lộ 3 - Thị Trấn Đông Anh', district: 'Đông Anh', lat: 21.1365, lng: 105.8475, thresholdMm: 14, depthCm: '20-35cm', bypass: 'Đi Võ Nguyên Giáp - Trường Sa' },
    { id: 'fl_44', name: 'Quốc Lộ 32 - Nhổn (Ga ĐS trên cao)', district: 'Bắc Từ Liêm', lat: 21.0552, lng: 105.7352, thresholdMm: 12, depthCm: '25-40cm', bypass: 'Đi đường 70 - Trịnh Văn Bô' },
    { id: 'fl_45', name: 'Ngọc Hồi - Văn Điển (QL1A)', district: 'Thanh Trì', lat: 20.9425, lng: 105.8442, thresholdMm: 12, depthCm: '25-45cm', bypass: 'Đi đường nối Pháp Vân - Tứ Hiệp' }
  ];

  // =========================================================================
  // 3. 12 CẦU LỚN VƯỢT SÔNG HỒNG & SÔNG ĐUỐNG (CẢNH BÁO GIÓ GIẬT TẠT ĐẦU XE)
  // =========================================================================
  var HANOI_BRIDGES = [
    { id: 'br_nhattan', name: 'Cầu Nhật Tân', river: 'Sông Hồng', lat: 21.0928, lng: 105.8215, heightFactor: 1.32 },
    { id: 'br_vinhtuy', name: 'Cầu Vĩnh Tuy', river: 'Sông Hồng', lat: 21.0068, lng: 105.8792, heightFactor: 1.28 },
    { id: 'br_thanhtri', name: 'Cầu Thanh Trì', river: 'Sông Hồng', lat: 20.9905, lng: 105.9015, heightFactor: 1.35 },
    { id: 'br_chuongduong', name: 'Cầu Chương Dương', river: 'Sông Hồng', lat: 21.0382, lng: 105.8628, heightFactor: 1.22 },
    { id: 'br_longbien', name: 'Cầu Long Biên', river: 'Sông Hồng', lat: 21.0432, lng: 105.8595, heightFactor: 1.20 },
    { id: 'br_thanglong', name: 'Cầu Thăng Long', river: 'Sông Hồng', lat: 21.0972, lng: 105.7868, heightFactor: 1.30 },
    { id: 'br_dongtru', name: 'Cầu Đông Trù', river: 'Sông Đuống', lat: 21.0738, lng: 105.8758, heightFactor: 1.24 },
    { id: 'br_duong', name: 'Cầu Đuống', river: 'Sông Đuống', lat: 21.0695, lng: 105.9102, heightFactor: 1.20 },
    { id: 'br_phudong', name: 'Cầu Phù Đổng', river: 'Sông Đuống', lat: 21.0445, lng: 105.9412, heightFactor: 1.26 },
    { id: 'br_thanglong_dl', name: 'Cầu Vượt Sông Đáy (ĐLTL)', river: 'Sông Đáy', lat: 21.0028, lng: 105.6845, heightFactor: 1.18 },
    { id: 'br_cuadong', name: 'Cầu Nhật Tựu / Hồng Phú', river: 'Sông Đáy', lat: 20.9585, lng: 105.7515, heightFactor: 1.15 },
    { id: 'br_vanphu', name: 'Cầu Mai Lĩnh (QL6)', river: 'Sông Đáy', lat: 20.9385, lng: 105.7245, heightFactor: 1.18 }
  ];

  // =========================================================================
  // 4. STATE & DOM REFERENCES
  // =========================================================================
  var currentMode = 'rain'; // 'rain' | 'temp' | 'flood' | 'aqi'
  var showRadarLayer = true;
  var showFloodLayer = true;
  var isDarkBaseMap = true;
  var weatherDataByZone = {};
  var aqiDataByZone = {};
  var userGpsCoord = null;
  var routeStartZoneId = 'cg_xuanthuy';
  var routeEndZoneId = 'dd_thaiha';
  var customRouteEndCoord = null;

  // Radar state
  var radarFrames = [];
  var radarHost = 'https://tilecache.rainviewer.com';
  var radarTileLayers = {};
  var currentRadarIdx = 0;
  var radarPlayTimer = null;

  // DOM
  var liveSummaryText = document.getElementById('liveSummaryText');
  var liveUpdatedMeta = document.getElementById('liveUpdatedMeta');
  var subHeaderStatus = document.getElementById('subHeaderStatus');
  var modeTabs = document.getElementById('modeTabs');
  var zoneSearchInput = document.getElementById('zoneSearchInput');
  var refreshWeatherBtn = document.getElementById('refreshWeatherBtn');
  var gpsLocateBtn = document.getElementById('gpsLocateBtn');
  var radarLayerToggleBtn = document.getElementById('radarLayerToggleBtn');
  var floodLayerToggleBtn = document.getElementById('floodLayerToggleBtn');
  var mapTileToggleBtn = document.getElementById('mapTileToggleBtn');
  var routeToggleBtn = document.getElementById('routeToggleBtn');
  var routeCard = document.getElementById('routeCard');
  var closeRouteBtn = document.getElementById('closeRouteBtn');
  var routeStartSelect = document.getElementById('routeStartSelect');
  var routeEndSelect = document.getElementById('routeEndSelect');
  var routeReportBox = document.getElementById('routeReportBox');
  var radarTimeBadge = document.getElementById('radarTimeBadge');
  var radarPlayBtn = document.getElementById('radarPlayBtn');
  var radarTimelineSlider = document.getElementById('radarTimelineSlider');
  var radarNowBtn = document.getElementById('radarNowBtn');
  var rankingTitle = document.getElementById('rankingTitle');
  var activeCountBadge = document.getElementById('activeCountBadge');
  var rankingChips = document.getElementById('rankingChips');

  // =========================================================================
  // 5. INITIALIZE LEAFLET MAP
  // =========================================================================
  var map = L.map('hanoiMap', {
    center: [21.0245, 105.8292],
    zoom: 12,
    minZoom: 9,
    maxZoom: 18,
    zoomControl: false,
    attributionControl: false
  });

  var darkTileLayer = L.tileLayer('https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png', {
    subdomains: 'abcd',
    maxZoom: 19
  }).addTo(map);

  var streetTileLayer = L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
    maxZoom: 19
  });

  var zoneLayerGroup = L.layerGroup().addTo(map);
  var floodLayerGroup = L.layerGroup().addTo(map);
  var bridgeLayerGroup = L.layerGroup().addTo(map);
  var routeLayerGroup = L.layerGroup().addTo(map);
  var gpsMarker = null;

  // =========================================================================
  // 6. GEOMETRY & WEATHER HELPERS
  // =========================================================================
  function haversineKm(lat1, lng1, lat2, lng2) {
    var R = 6371;
    var dLat = (lat2 - lat1) * Math.PI / 180;
    var dLng = (lng2 - lng1) * Math.PI / 180;
    var a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
            Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) *
            Math.sin(dLng / 2) * Math.sin(dLng / 2);
    return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  }

  function pointToSegmentDistKm(px, py, ax, ay, bx, by) {
    var dx = bx - ax;
    var dy = by - ay;
    if (dx === 0 && dy === 0) return haversineKm(px, py, ax, ay);
    var t = ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy);
    t = Math.max(0, Math.min(1, t));
    return haversineKm(px, py, ax + t * dx, ay + t * dy);
  }

  function findNearestZone(lat, lng) {
    var best = HANOI_ZONES[0];
    var bestDist = 999999;
    for (var i = 0; i < HANOI_ZONES.length; i++) {
      var z = HANOI_ZONES[i];
      var d = haversineKm(lat, lng, z.lat, z.lng);
      if (d < bestDist) {
        bestDist = d;
        best = z;
      }
    }
    return { zone: best, distKm: bestDist };
  }

  function windDegToDirVN(deg) {
    if (typeof deg !== 'number' || !isFinite(deg)) return 'ĐB';
    var dirs = ['Bắc', 'Đông Bắc', 'Đông', 'Đông Nam', 'Nam', 'Tây Nam', 'Tây', 'Tây Bắc'];
    return dirs[Math.round(((deg %= 360) < 0 ? deg + 360 : deg) / 45) % 8];
  }

  function wmoCodeToVN(code, rainMm) {
    if (rainMm >= 12 || code >= 95) return 'Mưa dông lớn';
    if (rainMm >= 4 || (code >= 63 && code <= 67) || (code >= 81 && code <= 82)) return 'Mưa rào vừa - to';
    if (rainMm > 0.1 || (code >= 51 && code <= 61) || code === 80) return 'Mưa nhỏ / Mưa phùn';
    if (code === 3) return 'Nhiều mây âm u';
    if (code === 2) return 'Mây rải rác';
    if (code === 1) return 'Ít mây, nắng nhẹ';
    return 'Trời quang tạnh ráo';
  }

  function computeFloodStatusForHotspot(hotspot) {
    var near = findNearestZone(hotspot.lat, hotspot.lng).zone;
    var w = weatherDataByZone[near.id] || {};
    var currentRain = Number(w.rainNow || 0);
    var rainNext1h = Number(w.rainNext1h || 0);
    var accumRain3h = Number(w.rainAccum3h || 0);
    // Effective water load at the street segment
    var effectiveMm = currentRain * 1.45 + accumRain3h * 0.65 + rainNext1h * 0.35;

    if (effectiveMm >= hotspot.thresholdMm * 1.35 || currentRain >= hotspot.thresholdMm) {
      return {
        level: 'danger',
        label: 'NGẬP SÂU (' + hotspot.depthCm + ')',
        effectiveMm: effectiveMm,
        zone: near,
        weather: w
      };
    }
    if (effectiveMm >= hotspot.thresholdMm * 0.62 || currentRain >= hotspot.thresholdMm * 0.5) {
      return {
        level: 'warn',
        label: 'Đọng nước 10-15cm',
        effectiveMm: effectiveMm,
        zone: near,
        weather: w
      };
    }
    return {
      level: 'safe',
      label: 'Khô ráo / Đi tốt',
      effectiveMm: effectiveMm,
      zone: near,
      weather: w
    };
  }

  // =========================================================================
  // 7. FETCH BATCH 60 HANOI ZONES (OPEN-METEO OR OPTIONAL CLOUDFLARE WORKER)
  // =========================================================================
  function getOptionalWorkerUrl() {
    try {
      var p = new URLSearchParams(window.location.search);
      var w = p.get('worker');
      if (w && w.indexOf('http') === 0) return w;
      return localStorage.getItem('vf_hn_weather_worker_url') || '';
    } catch (_) {
      return '';
    }
  }

  function parseSingleForecastNode(node) {
    var cur = (node && node.current) || {};
    var hourly = (node && node.hourly) || {};
    var nowIso = cur.time || '';
    var hTimes = hourly.time || [];
    var hPrecip = hourly.precipitation || [];
    var hProb = hourly.precipitation_probability || [];
    var hUv = hourly.uv_index || [];

    var nowIdx = 0;
    if (nowIso && hTimes.length) {
      var prefix = nowIso.slice(0, 13);
      for (var i = 0; i < hTimes.length; i++) {
        if (String(hTimes[i]).slice(0, 13) === prefix) {
          nowIdx = i;
          break;
        }
      }
    }

    var rainNow = Math.max(Number(cur.precipitation || 0), Number(cur.rain || 0), Number(cur.showers || 0));
    var rainNext1h = Number(hPrecip[Math.min(hTimes.length - 1, nowIdx + 1)] || 0);
    var rainProb = Number(hProb[nowIdx] || 0);
    var uvIndex = Number(hUv[nowIdx] || 0);

    var rainAccum3h = rainNow;
    for (var b = 1; b <= 2; b++) {
      if (nowIdx - b >= 0) {
        rainAccum3h += Number(hPrecip[nowIdx - b] || 0);
      }
    }

    return {
      temp: Number(cur.temperature_2m != null ? cur.temperature_2m : 27),
      feelsLike: Number(cur.apparent_temperature != null ? cur.apparent_temperature : 29),
      humidity: Number(cur.relative_humidity_2m != null ? cur.relative_humidity_2m : 75),
      rainNow: rainNow,
      rainNext1h: rainNext1h,
      rainAccum3h: rainAccum3h,
      rainProb: rainProb,
      weatherCode: Number(cur.weather_code || 0),
      windSpeed: Number(cur.wind_speed_10m || 0),
      windGust: Number(cur.wind_gusts_10m || 0),
      windDir: Number(cur.wind_direction_10m || 0),
      uvIndex: uvIndex
    };
  }

  function fetchAll60ZonesWeather() {
    liveUpdatedMeta.textContent = 'Đang tải 60 vùng...';
    var workerUrl = getOptionalWorkerUrl();

    var lats = HANOI_ZONES.map(function (z) { return z.lat.toFixed(4); }).join(',');
    var lngs = HANOI_ZONES.map(function (z) { return z.lng.toFixed(4); }).join(',');

    var weatherUrl = workerUrl
      ? (workerUrl.replace(/\/+$/, '') + '/hanoi-batch')
      : ('https://api.open-meteo.com/v1/forecast?latitude=' + lats +
         '&longitude=' + lngs +
         '&current=temperature_2m,relative_humidity_2m,apparent_temperature,precipitation,rain,showers,weather_code,wind_speed_10m,wind_direction_10m,wind_gusts_10m' +
         '&hourly=precipitation_probability,precipitation,uv_index' +
         '&timezone=Asia%2FBangkok&forecast_days=1');

    var aqiUrl = 'https://air-quality-api.open-meteo.com/v1/air-quality?latitude=' + lats +
                 '&longitude=' + lngs +
                 '&current=us_aqi,pm2_5,pm10&timezone=Asia%2FBangkok';

    var pWeather = fetch(weatherUrl).then(function (r) { return r.json(); });
    var pAqi = fetch(aqiUrl).then(function (r) { return r.json(); }).catch(function () { return null; });

    return Promise.all([pWeather, pAqi]).then(function (results) {
      var rawW = results[0];
      var rawA = results[1];

      if (rawW && rawW.zones && Array.isArray(rawW.zones)) {
        rawW = rawW.zones;
      }
      var listW = Array.isArray(rawW) ? rawW : [rawW];
      for (var i = 0; i < HANOI_ZONES.length; i++) {
        var z = HANOI_ZONES[i];
        var nodeW = listW[i] || listW[0] || {};
        weatherDataByZone[z.id] = parseSingleForecastNode(nodeW);
      }

      if (rawA) {
        var listA = Array.isArray(rawA) ? rawA : [rawA];
        for (var j = 0; j < HANOI_ZONES.length; j++) {
          var zA = HANOI_ZONES[j];
          var nodeA = (listA[j] && listA[j].current) || {};
          aqiDataByZone[zA.id] = {
            aqi: Number(nodeA.us_aqi != null ? nodeA.us_aqi : 68),
            pm25: Number(nodeA.pm2_5 != null ? nodeA.pm2_5 : 22),
            pm10: Number(nodeA.pm10 != null ? nodeA.pm10 : 38)
          };
        }
      }

      var now = new Date();
      var hh = String(now.getHours()).padStart(2, '0');
      var mm = String(now.getMinutes()).padStart(2, '0');
      liveUpdatedMeta.textContent = 'Cập nhật ' + hh + ':' + mm;

      renderMapOverlays();
      renderLiveSummaryBanner();
      renderBottomRanking();
      updateRouteReport();
    }).catch(function () {
      liveUpdatedMeta.textContent = 'Lỗi mạng — thử lại';
    });
  }

  // =========================================================================
  // 8. RAINVIEWER LIVE DOPPLER RADAR + 30M NOWCAST
  // =========================================================================
  function fetchRainViewerManifest() {
    return fetch('https://api.rainviewer.com/public/weather-maps.json')
      .then(function (r) { return r.json(); })
      .then(function (data) {
        if (!data || !data.radar) return;
        radarHost = data.host || 'https://tilecache.rainviewer.com';
        var past = (data.radar.past || []).slice(-6); // last 60 mins
        var nowcast = data.radar.nowcast || [];      // next 30 mins
        radarFrames = [];

        past.forEach(function (f, idx) {
          radarFrames.push({
            time: f.time,
            path: f.path,
            isNowcast: false,
            isLatestPast: idx === past.length - 1
          });
        });

        nowcast.forEach(function (f) {
          radarFrames.push({
            time: f.time,
            path: f.path,
            isNowcast: true,
            isLatestPast: false
          });
        });

        if (radarFrames.length > 0) {
          var latestPastIdx = Math.max(0, past.length - 1);
          radarTimelineSlider.min = 0;
          radarTimelineSlider.max = radarFrames.length - 1;
          radarTimelineSlider.value = latestPastIdx;
          showRadarFrameAtIndex(latestPastIdx);
        }
      })
      .catch(function () {});
  }

  function showRadarFrameAtIndex(idx) {
    if (!radarFrames.length) return;
    idx = Math.max(0, Math.min(radarFrames.length - 1, Number(idx) || 0));
    currentRadarIdx = idx;
    radarTimelineSlider.value = idx;

    // Hide other radar layers
    Object.keys(radarTileLayers).forEach(function (k) {
      var lyr = radarTileLayers[k];
      if (lyr && map.hasLayer(lyr) && Number(k) !== idx) {
        map.removeLayer(lyr);
      }
    });

    var frame = radarFrames[idx];
    if (showRadarLayer && frame && frame.path) {
      if (!radarTileLayers[idx]) {
        var tileUrl = radarHost + frame.path + '/256/{z}/{x}/{y}/2/1_1.png';
        radarTileLayers[idx] = L.tileLayer(tileUrl, {
          tileSize: 256,
          opacity: 0.72,
          zIndex: 220,
          maxNativeZoom: 7,
          maxZoom: 19
        });
      }
      if (!map.hasLayer(radarTileLayers[idx])) {
        radarTileLayers[idx].addTo(map);
      }
    }

    // Format badge time
    var d = new Date(frame.time * 1000);
    var hh = String(d.getHours()).padStart(2, '0');
    var mm = String(d.getMinutes()).padStart(2, '0');
    var diffMin = Math.round((frame.time * 1000 - Date.now()) / 60000);

    if (frame.isLatestPast || Math.abs(diffMin) <= 6) {
      radarTimeBadge.className = 'radar-time-badge';
      radarTimeBadge.textContent = 'Hiện tại (' + hh + ':' + mm + ')';
    } else if (frame.isNowcast || diffMin > 0) {
      radarTimeBadge.className = 'radar-time-badge nowcast';
      radarTimeBadge.textContent = 'Dự báo +' + Math.max(5, diffMin) + ' phút (' + hh + ':' + mm + ')';
    } else {
      radarTimeBadge.className = 'radar-time-badge';
      radarTimeBadge.textContent = Math.abs(diffMin) + ' phút trước (' + hh + ':' + mm + ')';
    }
  }

  // =========================================================================
  // 9. RENDER 60 MICRO-ZONES, 45 FLOOD HOTSPOTS & 12 BRIDGES
  // =========================================================================
  function getZonePillSpec(z) {
    var w = weatherDataByZone[z.id] || {
      temp: 27, feelsLike: 29, rainNow: 0, rainNext1h: 0, rainProb: 0, windSpeed: 8, windGust: 14, uvIndex: 3
    };
    var a = aqiDataByZone[z.id] || { aqi: 65, pm25: 19 };

    if (currentMode === 'rain') {
      var r = w.rainNow;
      var prob = w.rainProb;
      if (r >= 8) {
        return { cls: 'lvl-heavy', val: r.toFixed(1) + 'mm/h' };
      }
      if (r >= 1.5) {
        return { cls: 'lvl-mod', val: r.toFixed(1) + 'mm/h' };
      }
      if (r > 0.1 || prob >= 55) {
        return { cls: 'lvl-light', val: r > 0.1 ? (r.toFixed(1) + 'mm') : (prob + '% mưa') };
      }
      return { cls: 'lvl-clear', val: Math.round(w.temp) + '° • Khô' };
    }

    if (currentMode === 'temp') {
      var fl = Math.round(w.feelsLike);
      var t = Math.round(w.temp);
      var clsT = fl >= 38 ? 'lvl-heavy' : (fl >= 34 ? 'lvl-mod' : (fl <= 16 ? 'lvl-light' : 'lvl-clear'));
      return { cls: clsT, val: t + '° (Đường ' + fl + '°)' };
    }

    if (currentMode === 'aqi') {
      var aqi = Math.round(a.aqi);
      var clsA = aqi >= 151 ? 'lvl-heavy' : (aqi >= 101 ? 'lvl-mod' : (aqi >= 51 ? 'lvl-light' : 'lvl-clear'));
      return { cls: clsA, val: 'AQI ' + aqi };
    }

    // Flood & Bridge mode: highlight gusts & local rain
    var g = Math.round(w.windGust);
    var clsF = w.rainNow >= 5 || g >= 40 ? 'lvl-heavy' : (w.rainNow >= 1 || g >= 28 ? 'lvl-mod' : 'lvl-clear');
    return { cls: clsF, val: 'Gió ' + g + 'km/h' };
  }

  function buildZonePopupHtml(z) {
    var w = weatherDataByZone[z.id] || {};
    var a = aqiDataByZone[z.id] || {};
    var desc = wmoCodeToVN(w.weatherCode || 0, w.rainNow || 0);
    var windDirStr = windDegToDirVN(w.windDir);
    var gmapsUrl = 'https://www.google.com/maps/dir/?api=1&destination=' + z.lat.toFixed(6) + ',' + z.lng.toFixed(6) + '&travelmode=two-wheeler';

    return (
      '<div class="popup-title">' + z.name + '</div>' +
      '<div class="popup-sub">Quận/Huyện: <strong>' + z.district + '</strong> • ' + desc + '</div>' +
      '<div class="popup-grid">' +
        '<div class="popup-metric"><div class="popup-metric-k">Lượng mưa hiện tại</div><div class="popup-metric-v">' + Number(w.rainNow || 0).toFixed(1) + ' mm/h (' + Math.round(w.rainProb || 0) + '%)</div></div>' +
        '<div class="popup-metric"><div class="popup-metric-k">Dự báo 60p tới</div><div class="popup-metric-v">' + Number(w.rainNext1h || 0).toFixed(1) + ' mm/h</div></div>' +
        '<div class="popup-metric"><div class="popup-metric-k">Nhiệt độ / Mặt đường</div><div class="popup-metric-v">' + Math.round(w.temp || 27) + '°C / ' + Math.round(w.feelsLike || 29) + '°C</div></div>' +
        '<div class="popup-metric"><div class="popup-metric-k">Gió &amp; Gió giật</div><div class="popup-metric-v">' + Math.round(w.windSpeed || 0) + ' - ' + Math.round(w.windGust || 0) + ' km/h (' + windDirStr + ')</div></div>' +
        '<div class="popup-metric"><div class="popup-metric-k">Bụi mịn US AQI</div><div class="popup-metric-v">' + Math.round(a.aqi || 65) + ' (PM2.5: ' + Math.round(a.pm25 || 20) + ')</div></div>' +
        '<div class="popup-metric"><div class="popup-metric-k">Độ ẩm / Tia UV</div><div class="popup-metric-v">' + Math.round(w.humidity || 75) + '% • UV ' + Number(w.uvIndex || 0).toFixed(1) + '</div></div>' +
      '</div>' +
      '<div class="popup-actions">' +
        '<button type="button" class="popup-btn" onclick="window.__hnSetRoutePoint(\'start\', \'' + z.id + '\')">Đặt Điểm Đón</button>' +
        '<button type="button" class="popup-btn" onclick="window.__hnSetRoutePoint(\'end\', \'' + z.id + '\')">Đặt Điểm Giao</button>' +
        '<a class="popup-btn" href="' + gmapsUrl + '" target="_blank" rel="noopener">Mở Map</a>' +
      '</div>'
    );
  }

  function renderMapOverlays() {
    zoneLayerGroup.clearLayers();
    floodLayerGroup.clearLayers();
    bridgeLayerGroup.clearLayers();

    var q = (zoneSearchInput.value || '').trim().toLowerCase();

    // 1. Render 60 Micro-Zones (In 'flood' mode without search filter, keep pills minimal so flood pins stand out)
    HANOI_ZONES.forEach(function (z) {
      if (q && z.name.toLowerCase().indexOf(q) === -1 && z.district.toLowerCase().indexOf(q) === -1) {
        return;
      }
      if (currentMode === 'flood' && !q && !z.urban) {
        return;
      }

      var spec = getZonePillSpec(z);
      var iconHtml =
        '<div class="hn-zone-pill ' + spec.cls + '">' +
          '<span class="z-name">' + z.name + '</span>' +
          '<span class="z-val">' + spec.val + '</span>' +
        '</div>';

      var marker = L.marker([z.lat, z.lng], {
        icon: L.divIcon({
          className: '',
          html: iconHtml,
          iconSize: [0, 0]
        })
      });

      marker.bindPopup(buildZonePopupHtml(z), { maxWidth: 290 });
      zoneLayerGroup.addLayer(marker);
    });

    // 2. Render 45 Flood Hotspots (Always shown when flood mode is active or flood toggle is ON)
    if (showFloodLayer || currentMode === 'flood') {
      HANOI_FLOOD_HOTSPOTS.forEach(function (fl) {
        var st = computeFloodStatusForHotspot(fl);
        var matchSearch = q && (fl.name.toLowerCase().indexOf(q) !== -1 || fl.district.toLowerCase().indexOf(q) !== -1);

        // When not in 'flood' tab and not searching, only render hotspots that have active rain/flood warning OR major hotspots at zoom >= 13
        if (currentMode !== 'flood' && !matchSearch && st.level === 'safe' && map.getZoom() < 13) {
          return;
        }

        var pinCls = st.level === 'danger' ? 'flood-danger' : (st.level === 'warn' ? 'flood-warn' : 'flood-safe');
        var shortTag = st.level === 'danger' ? ('NGẬP: ' + fl.name.split('(')[0]) : (st.level === 'warn' ? ('Đọng: ' + fl.name.split('(')[0]) : ('Rốn ngập: ' + fl.name.split('-')[0]));

        var m = L.marker([fl.lat, fl.lng], {
          icon: L.divIcon({
            className: '',
            html: '<div class="hn-hazard-pin ' + pinCls + '">' + shortTag + '</div>',
            iconSize: [0, 0]
          })
        });

        var popHtml =
          '<div class="popup-title">Điểm Ngập: ' + fl.name + '</div>' +
          '<div class="popup-sub">Quận: <strong>' + fl.district + '</strong> • Trạng thái: <strong>' + st.label + '</strong></div>' +
          '<div class="popup-grid">' +
            '<div class="popup-metric"><div class="popup-metric-k">Mưa tại khu vực</div><div class="popup-metric-v">' + Number((st.weather && st.weather.rainNow) || 0).toFixed(1) + ' mm/h</div></div>' +
            '<div class="popup-metric"><div class="popup-metric-k">Độ sâu khi mưa lớn</div><div class="popup-metric-v">' + fl.depthCm + '</div></div>' +
          '</div>' +
          '<div style="background:rgba(15,23,42,0.9);border:1px solid rgba(245,158,11,0.35);border-radius:8px;padding:6px 8px;font-size:11.5px;color:#fde68a;">' +
            '<strong>Lộ trình né ngập:</strong> ' + fl.bypass +
          '</div>';

        m.bindPopup(popHtml, { maxWidth: 285 });
        floodLayerGroup.addLayer(m);
      });
    }

    // 3. Render 12 Major River Bridges (In 'flood' mode or when wind gusts >= 30 km/h)
    HANOI_BRIDGES.forEach(function (br) {
      var near = findNearestZone(br.lat, br.lng).zone;
      var w = weatherDataByZone[near.id] || {};
      var bridgeGust = Math.round((w.windGust || 12) * br.heightFactor);
      var bridgeWind = Math.round((w.windSpeed || 8) * br.heightFactor);
      var isHighGust = bridgeGust >= 34;

      if (currentMode !== 'flood' && !isHighGust) return;

      var clsB = isHighGust ? 'bridge-pin gust-warn' : 'bridge-pin';
      var m = L.marker([br.lat, br.lng], {
        icon: L.divIcon({
          className: '',
          html: '<div class="hn-hazard-pin ' + clsB + '">' + br.name + ' • Gió ' + bridgeGust + 'km/h</div>',
          iconSize: [0, 0]
        })
      });

      var advice = bridgeGust >= 45
        ? 'CẢNH BÁO ĐỎ: Gió giật cực mạnh trên nhịp chính, xe máy dễ bị tạt đầu xe. Nên đi chậm sát làn trong hoặc chờ ngớt dông!'
        : (bridgeGust >= 34
            ? 'CẢNH BÁO VÀNG: Gió tạt ngang khá mạnh trên cầu, giữ chắc tay lái.'
            : 'Gió trên cầu ổn định, lưu thông bình thường.');

      m.bindPopup(
        '<div class="popup-title">' + br.name + ' (' + br.river + ')</div>' +
        '<div class="popup-sub">Gió mặt cầu: <strong>' + bridgeWind + ' km/h</strong> • Gió giật: <strong>' + bridgeGust + ' km/h</strong></div>' +
        '<div style="background:rgba(15,23,42,0.9);border:1px solid rgba(129,140,248,0.35);border-radius:8px;padding:6px 8px;font-size:11.5px;color:#e0e7ff;">' +
          advice +
        '</div>',
        { maxWidth: 275 }
      );
      bridgeLayerGroup.addLayer(m);
    });
  }

  // =========================================================================
  // 10. LIVE SUMMARY BANNER & BOTTOM RANKING STRIP
  // =========================================================================
  function renderLiveSummaryBanner() {
    var rainingZones = [];
    var maxRainZone = null;
    var maxTempZone = null;

    HANOI_ZONES.forEach(function (z) {
      var w = weatherDataByZone[z.id];
      if (!w) return;
      if (w.rainNow > 0.15) rainingZones.push({ zone: z, w: w });
      if (!maxRainZone || w.rainNow > maxRainZone.w.rainNow) maxRainZone = { zone: z, w: w };
      if (!maxTempZone || w.feelsLike > maxTempZone.w.feelsLike) maxTempZone = { zone: z, w: w };
    });

    var activeFloods = HANOI_FLOOD_HOTSPOTS.filter(function (fl) {
      return computeFloodStatusForHotspot(fl).level !== 'safe';
    });

    var refPoint = userGpsCoord || { lat: map.getCenter().lat, lng: map.getCenter().lng };
    var nearest = findNearestZone(refPoint.lat, refPoint.lng);
    var localW = weatherDataByZone[nearest.zone.id] || {};

    if (rainingZones.length > 0) {
      liveSummaryText.innerHTML =
        '<strong>' + nearest.zone.name + ':</strong> ' + wmoCodeToVN(localW.weatherCode || 0, localW.rainNow || 0) +
        ' (' + Math.round(localW.temp || 27) + '°C) • Đang có <strong>' + rainingZones.length + '/60 vùng mưa</strong> (Mưa to nhất: ' +
        maxRainZone.zone.name + ' ' + maxRainZone.w.rainNow.toFixed(1) + 'mm/h)' +
        (activeFloods.length ? (' • <strong style="color:#fca5a5;">' + activeFloods.length + ' điểm báo ngập!</strong>') : '');
    } else {
      liveSummaryText.innerHTML =
        '<strong>' + nearest.zone.name + ':</strong> Tạnh ráo (' + Math.round(localW.temp || 27) + '°C, mặt đường ' +
        Math.round(localW.feelsLike || 29) + '°C) • Toàn Hà Nội <strong>60/60 tiểu vùng khô ráo</strong>, 45 điểm đen không ngập.';
    }
  }

  function renderBottomRanking() {
    rankingChips.innerHTML = '';
    var items = [];

    if (currentMode === 'flood') {
      rankingTitle.textContent = '45 Điểm Đen Ngập Úng & Cầu Lớn Hà Nội (Chạm để bay tới)';
      activeCountBadge.textContent = '45 điểm ngập';
      HANOI_FLOOD_HOTSPOTS.forEach(function (fl) {
        var st = computeFloodStatusForHotspot(fl);
        items.push({
          lat: fl.lat,
          lng: fl.lng,
          name: fl.name,
          sub: fl.district + ' • ' + st.label,
          cls: st.level === 'danger' ? 'flood-alert' : (st.level === 'warn' ? 'rain-alert' : ''),
          score: st.effectiveMm * 100 + (st.level === 'danger' ? 1000 : 0)
        });
      });
    } else if (currentMode === 'temp') {
      rankingTitle.textContent = 'Khu Vực Nóng Bức Mặt Đường Nhất Lúc Này';
      activeCountBadge.textContent = '60 tiểu vùng';
      HANOI_ZONES.forEach(function (z) {
        var w = weatherDataByZone[z.id] || {};
        items.push({
          lat: z.lat,
          lng: z.lng,
          name: z.name,
          sub: z.district + ' • Mặt đường ' + Math.round(w.feelsLike || 29) + '°C (UV ' + Number(w.uvIndex || 0).toFixed(1) + ')',
          cls: (w.feelsLike || 0) >= 36 ? 'flood-alert' : '',
          score: w.feelsLike || 0
        });
      });
    } else if (currentMode === 'aqi') {
      rankingTitle.textContent = 'Khu Vực Bụi Mịn AQI Cao Nhất Lúc Này';
      activeCountBadge.textContent = '60 tiểu vùng';
      HANOI_ZONES.forEach(function (z) {
        var a = aqiDataByZone[z.id] || {};
        items.push({
          lat: z.lat,
          lng: z.lng,
          name: z.name,
          sub: z.district + ' • AQI ' + Math.round(a.aqi || 65) + ' (PM2.5: ' + Math.round(a.pm25 || 20) + ')',
          cls: (a.aqi || 0) >= 120 ? 'flood-alert' : '',
          score: a.aqi || 0
        });
      });
    } else {
      rankingTitle.textContent = 'Bảng Xếp Hạng Mưa & Xác Suất Mưa 60 Tiểu Vùng';
      activeCountBadge.textContent = '60 tiểu vùng';
      HANOI_ZONES.forEach(function (z) {
        var w = weatherDataByZone[z.id] || {};
        items.push({
          lat: z.lat,
          lng: z.lng,
          name: z.name,
          sub: z.district + ' • ' + Number(w.rainNow || 0).toFixed(1) + 'mm/h • XS ' + Math.round(w.rainProb || 0) + '%',
          cls: (w.rainNow || 0) > 0.2 ? 'rain-alert' : '',
          score: (w.rainNow || 0) * 100 + (w.rainProb || 0)
        });
      });
    }

    items.sort(function (a, b) { return b.score - a.score; });

    items.slice(0, 18).forEach(function (it) {
      var chip = document.createElement('div');
      chip.className = 'rank-chip ' + (it.cls || '');
      chip.innerHTML =
        '<div class="rank-chip-name">' + it.name + '</div>' +
        '<div class="rank-chip-val">' + it.sub + '</div>';
      chip.addEventListener('click', function () {
        map.flyTo([it.lat, it.lng], 15, { duration: 0.65 });
      });
      rankingChips.appendChild(chip);
    });
  }

  // =========================================================================
  // 11. ROUTE CORRIDOR WEATHER & FLOOD CHECKER (SOI LỘ TRÌNH ĐÓN -> GIAO)
  // =========================================================================
  function populateRouteSelects() {
    routeStartSelect.innerHTML = '';
    routeEndSelect.innerHTML = '';

    HANOI_ZONES.forEach(function (z) {
      var opt1 = document.createElement('option');
      opt1.value = z.id;
      opt1.textContent = 'Đón: ' + z.name + ' (' + z.district + ')';
      routeStartSelect.appendChild(opt1);

      var opt2 = document.createElement('option');
      opt2.value = z.id;
      opt2.textContent = 'Giao: ' + z.name + ' (' + z.district + ')';
      routeEndSelect.appendChild(opt2);
    });

    if (customRouteEndCoord) {
      var optCustom = document.createElement('option');
      optCustom.value = '__custom_dest__';
      optCustom.textContent = 'Giao (Bắn Map): ' + (customRouteEndCoord.label || 'Tọa độ đơn hàng');
      routeEndSelect.insertBefore(optCustom, routeEndSelect.firstChild);
      routeEndZoneId = '__custom_dest__';
    }

    routeStartSelect.value = routeStartZoneId;
    routeEndSelect.value = routeEndZoneId;
  }

  function resolveEndpoint(idOrCustom) {
    if (idOrCustom === '__custom_dest__' && customRouteEndCoord) {
      var near = findNearestZone(customRouteEndCoord.lat, customRouteEndCoord.lng).zone;
      return {
        name: customRouteEndCoord.label || ('Điểm Giao (' + near.name + ')'),
        lat: customRouteEndCoord.lat,
        lng: customRouteEndCoord.lng,
        zone: near
      };
    }
    for (var i = 0; i < HANOI_ZONES.length; i++) {
      if (HANOI_ZONES[i].id === idOrCustom) {
        return {
          name: HANOI_ZONES[i].name,
          lat: HANOI_ZONES[i].lat,
          lng: HANOI_ZONES[i].lng,
          zone: HANOI_ZONES[i]
        };
      }
    }
    var def = HANOI_ZONES[0];
    return { name: def.name, lat: def.lat, lng: def.lng, zone: def };
  }

  function updateRouteReport() {
    routeLayerGroup.clearLayers();
    if (!routeCard.classList.contains('open')) return;

    var ptA = resolveEndpoint(routeStartSelect.value || routeStartZoneId);
    var ptB = resolveEndpoint(routeEndSelect.value || routeEndZoneId);
    var wA = weatherDataByZone[ptA.zone.id] || {};
    var wB = weatherDataByZone[ptB.zone.id] || {};
    var distKm = haversineKm(ptA.lat, ptA.lng, ptB.lat, ptB.lng);

    // Draw corridor line on map
    var poly = L.polyline([[ptA.lat, ptA.lng], [ptB.lat, ptB.lng]], {
      color: '#38bdf8',
      weight: 4,
      dashArray: '8, 6',
      opacity: 0.9
    }).addTo(routeLayerGroup);

    // Check flood hotspots within 0.85km of the route corridor
    var corridorFloods = [];
    HANOI_FLOOD_HOTSPOTS.forEach(function (fl) {
      var dCorridor = pointToSegmentDistKm(fl.lat, fl.lng, ptA.lat, ptA.lng, ptB.lat, ptB.lng);
      if (dCorridor <= 0.85) {
        var st = computeFloodStatusForHotspot(fl);
        corridorFloods.push({ hotspot: fl, status: st, distKm: dCorridor });
      }
    });

    var activeHazards = corridorFloods.filter(function (c) { return c.status.level !== 'safe'; });
    var floodLine = '';
    if (activeHazards.length > 0) {
      floodLine = '<div style="color:#fca5a5;margin-top:4px;"><strong>CẢNH BÁO NGẬP DỌC ĐƯỜNG:</strong> Đi ngang ' +
        activeHazards.map(function (c) { return c.hotspot.name + ' (' + c.status.label + ')'; }).join('; ') + '</div>';
    } else if (corridorFloods.length > 0) {
      floodLine = '<div style="color:#fde68a;margin-top:4px;">Tuyến đường đi qua gần <strong>' + corridorFloods.length +
        ' điểm trũng</strong> (' + corridorFloods.slice(0, 3).map(function (c) { return c.hotspot.name.split('-')[0].trim(); }).join(', ') +
        ') — Hiện tại <strong>Khô ráo / Đi tốt</strong>.</div>';
    } else {
      floodLine = '<div style="color:#6ee7b7;margin-top:4px;">Tuyến đường không cắt qua điểm đen ngập úng nào.</div>';
    }

    routeReportBox.innerHTML =
      '<div><strong>Đón (' + ptA.name + '):</strong> ' + wmoCodeToVN(wA.weatherCode || 0, wA.rainNow || 0) +
      ' • ' + Math.round(wA.temp || 27) + '°C • Mưa ' + Number(wA.rainNow || 0).toFixed(1) + 'mm/h</div>' +
      '<div><strong>Giao (' + ptB.name + ' • ' + distKm.toFixed(1) + 'km):</strong> ' + wmoCodeToVN(wB.weatherCode || 0, wB.rainNow || 0) +
      ' • ' + Math.round(wB.temp || 27) + '°C • Mưa ' + Number(wB.rainNow || 0).toFixed(1) + 'mm/h</div>' +
      floodLine;

    return poly;
  }

  window.__hnSetRoutePoint = function (which, zoneId) {
    routeCard.classList.add('open');
    routeToggleBtn.classList.add('active');
    if (which === 'start') {
      routeStartZoneId = zoneId;
      routeStartSelect.value = zoneId;
    } else {
      routeEndZoneId = zoneId;
      routeEndSelect.value = zoneId;
    }
    var poly = updateRouteReport();
    map.closePopup();
    if (poly) {
      map.fitBounds(poly.getBounds(), { padding: [70, 70], maxZoom: 14 });
    }
  };

  // =========================================================================
  // 12. EVENT LISTENERS & URL QUERY DEEP-LINKING (?lat=...&lng=...&label=...)
  // =========================================================================
  modeTabs.addEventListener('click', function (ev) {
    var btn = ev.target.closest('.mode-tab');
    if (!btn) return;
    var nextMode = btn.getAttribute('data-mode');
    if (!nextMode) return;
    currentMode = nextMode;
    Array.prototype.forEach.call(modeTabs.querySelectorAll('.mode-tab'), function (b) {
      b.classList.toggle('active', b === btn);
    });
    renderMapOverlays();
    renderBottomRanking();
  });

  zoneSearchInput.addEventListener('input', function () {
    renderMapOverlays();
    var q = (zoneSearchInput.value || '').trim().toLowerCase();
    if (q.length >= 2) {
      for (var i = 0; i < HANOI_ZONES.length; i++) {
        var z = HANOI_ZONES[i];
        if (z.name.toLowerCase().indexOf(q) !== -1 || z.district.toLowerCase().indexOf(q) !== -1) {
          map.flyTo([z.lat, z.lng], 14, { duration: 0.45 });
          return;
        }
      }
      for (var j = 0; j < HANOI_FLOOD_HOTSPOTS.length; j++) {
        var fl = HANOI_FLOOD_HOTSPOTS[j];
        if (fl.name.toLowerCase().indexOf(q) !== -1) {
          map.flyTo([fl.lat, fl.lng], 15, { duration: 0.45 });
          return;
        }
      }
    }
  });

  refreshWeatherBtn.addEventListener('click', function () {
    fetchAll60ZonesWeather();
    fetchRainViewerManifest();
  });

  gpsLocateBtn.addEventListener('click', function () {
    if (!navigator.geolocation) return;
    gpsLocateBtn.classList.add('active');
    navigator.geolocation.getCurrentPosition(function (pos) {
      userGpsCoord = { lat: pos.coords.latitude, lng: pos.coords.longitude };
      if (gpsMarker) map.removeLayer(gpsMarker);
      gpsMarker = L.circleMarker([userGpsCoord.lat, userGpsCoord.lng], {
        radius: 8,
        color: '#00e676',
        weight: 3,
        fillColor: '#00e676',
        fillOpacity: 0.85
      }).addTo(map).bindPopup('<strong>Vị trí GPS của bạn</strong>');
      map.flyTo([userGpsCoord.lat, userGpsCoord.lng], 14, { duration: 0.65 });

      var near = findNearestZone(userGpsCoord.lat, userGpsCoord.lng).zone;
      routeStartZoneId = near.id;
      routeStartSelect.value = near.id;
      renderLiveSummaryBanner();
      updateRouteReport();
    }, function () {
      gpsLocateBtn.classList.remove('active');
    }, { enableHighAccuracy: true, timeout: 8000 });
  });

  radarLayerToggleBtn.addEventListener('click', function () {
    showRadarLayer = !showRadarLayer;
    radarLayerToggleBtn.classList.toggle('active', showRadarLayer);
    if (!showRadarLayer) {
      Object.keys(radarTileLayers).forEach(function (k) {
        if (radarTileLayers[k] && map.hasLayer(radarTileLayers[k])) {
          map.removeLayer(radarTileLayers[k]);
        }
      });
    } else {
      showRadarFrameAtIndex(currentRadarIdx);
    }
  });

  floodLayerToggleBtn.addEventListener('click', function () {
    showFloodLayer = !showFloodLayer;
    floodLayerToggleBtn.classList.toggle('active', showFloodLayer);
    renderMapOverlays();
  });

  mapTileToggleBtn.addEventListener('click', function () {
    isDarkBaseMap = !isDarkBaseMap;
    mapTileToggleBtn.classList.toggle('active', !isDarkBaseMap);
    if (isDarkBaseMap) {
      if (map.hasLayer(streetTileLayer)) map.removeLayer(streetTileLayer);
      if (!map.hasLayer(darkTileLayer)) darkTileLayer.addTo(map);
    } else {
      if (map.hasLayer(darkTileLayer)) map.removeLayer(darkTileLayer);
      if (!map.hasLayer(streetTileLayer)) streetTileLayer.addTo(map);
    }
  });

  routeToggleBtn.addEventListener('click', function () {
    var open = !routeCard.classList.contains('open');
    routeCard.classList.toggle('open', open);
    routeToggleBtn.classList.toggle('active', open);
    updateRouteReport();
  });

  closeRouteBtn.addEventListener('click', function () {
    routeCard.classList.remove('open');
    routeToggleBtn.classList.remove('active');
    routeLayerGroup.clearLayers();
  });

  routeStartSelect.addEventListener('change', function () {
    routeStartZoneId = routeStartSelect.value;
    updateRouteReport();
  });

  routeEndSelect.addEventListener('change', function () {
    routeEndZoneId = routeEndSelect.value;
    updateRouteReport();
  });

  radarTimelineSlider.addEventListener('input', function () {
    showRadarFrameAtIndex(Number(radarTimelineSlider.value));
  });

  radarNowBtn.addEventListener('click', function () {
    if (radarPlayTimer) {
      clearInterval(radarPlayTimer);
      radarPlayTimer = null;
      radarPlayBtn.textContent = 'Chạy';
    }
    var latestIdx = 0;
    for (var i = 0; i < radarFrames.length; i++) {
      if (radarFrames[i].isLatestPast) {
        latestIdx = i;
        break;
      }
    }
    showRadarFrameAtIndex(latestIdx);
  });

  radarPlayBtn.addEventListener('click', function () {
    if (radarPlayTimer) {
      clearInterval(radarPlayTimer);
      radarPlayTimer = null;
      radarPlayBtn.textContent = 'Chạy';
      return;
    }
    if (!radarFrames.length) return;
    radarPlayBtn.textContent = 'Dừng';
    radarPlayTimer = setInterval(function () {
      var next = (currentRadarIdx + 1) % radarFrames.length;
      showRadarFrameAtIndex(next);
    }, 650);
  });

  map.on('zoomend', function () {
    renderMapOverlays();
  });

  // Handle incoming ?lat=...&lng=...&label=... from map.html (Bắn Map Xanh)
  function checkIncomingUrlCoords() {
    try {
      var p = new URLSearchParams(window.location.search);
      var lat = parseFloat(p.get('lat') || p.get('destLat') || '');
      var lng = parseFloat(p.get('lng') || p.get('destLng') || '');
      var label = p.get('label') || p.get('destLabel') || '';
      if (isFinite(lat) && isFinite(lng) && lat > 19.5 && lat < 22.5 && lng > 104.5 && lng < 107.0) {
        customRouteEndCoord = { lat: lat, lng: lng, label: label || (lat.toFixed(5) + ', ' + lng.toFixed(5)) };
        routeCard.classList.add('open');
        routeToggleBtn.classList.add('active');
        setTimeout(function () {
          map.flyTo([lat, lng], 15, { duration: 0.7 });
        }, 350);
      }
    } catch (_) {}
  }

  // Boot
  checkIncomingUrlCoords();
  populateRouteSelects();
  fetchAll60ZonesWeather();
  fetchRainViewerManifest();

  // Auto-refresh every 3 minutes
  setInterval(function () {
    if (document.visibilityState === 'visible') {
      fetchAll60ZonesWeather();
      fetchRainViewerManifest();
    }
  }, 180000);
})();
