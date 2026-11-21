// C:/Users/Acer/.gemini/antigravity/scratch/pin-nhiet-do-ts/Sources/DashcamApp/RingStorageManager.m
// Context: Objective-C Implementation / SQLite WAL Ring Buffer & Daily Quota / iOS 12.0+ arm64

#import "RingStorageManager.h"
#import "DashcamConfig.h"
#import <sqlite3.h>

@implementation DashcamClipRecord
@end

@interface RingStorageManager () {
    sqlite3 *_db;
    dispatch_queue_t _ioQueue;
    NSString *_loopDir;
    NSString *_lockedDir;
    NSString *_tempDir;
    NSDateFormatter *_fileDateFmt;
    NSDateFormatter *_dayKeyFmt;
}
@end

@implementation RingStorageManager

+ (instancetype)sharedManager {
    static RingStorageManager *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[RingStorageManager alloc] init];
    });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _ioQueue = dispatch_queue_create("com.vn.cooldash6.storage", DISPATCH_QUEUE_SERIAL);
        _fileDateFmt = [[NSDateFormatter alloc] init];
        _fileDateFmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        _fileDateFmt.dateFormat = @"yyyyMMdd_HHmmss";

        _dayKeyFmt = [[NSDateFormatter alloc] init];
        _dayKeyFmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        _dayKeyFmt.dateFormat = @"yyyy-MM-dd";

        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        _loopDir   = [docs stringByAppendingPathComponent:@"LoopClips"];
        _lockedDir = [docs stringByAppendingPathComponent:@"LockedClips"];
        _tempDir   = [NSTemporaryDirectory() stringByAppendingPathComponent:@"CoolDash6Uploads"];

        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:_loopDir withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createDirectoryAtPath:_lockedDir withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createDirectoryAtPath:_tempDir withIntermediateDirectories:YES attributes:nil error:nil];

        // Clean leftover temp multipart files from previous runs
        NSArray<NSString *> *temps = [fm contentsOfDirectoryAtPath:_tempDir error:nil];
        for (NSString *f in temps) {
            [fm removeItemAtPath:[_tempDir stringByAppendingPathComponent:f] error:nil];
        }

        [self openDatabaseAtPath:[docs stringByAppendingPathComponent:@"queue.sqlite"]];
    }
    return self;
}

- (void)dealloc {
    if (_db) {
        sqlite3_close(_db);
        _db = NULL;
    }
}

- (void)openDatabaseAtPath:(NSString *)dbPath {
    if (sqlite3_open(dbPath.UTF8String, &_db) != SQLITE_OK) {
        if (_db) {
            sqlite3_close(_db);
            _db = NULL;
        }
        return;
    }
    sqlite3_exec(_db, "PRAGMA journal_mode=WAL;", NULL, NULL, NULL);
    sqlite3_exec(_db, "PRAGMA synchronous=NORMAL;", NULL, NULL, NULL);

    const char *schemaSQL =
        "CREATE TABLE IF NOT EXISTS clips ("
        "  id INTEGER PRIMARY KEY AUTOINCREMENT,"
        "  filename TEXT NOT NULL,"
        "  full_path TEXT NOT NULL UNIQUE,"
        "  caption TEXT,"
        "  start_epoch REAL NOT NULL,"
        "  duration_sec INTEGER NOT NULL,"
        "  size_bytes INTEGER NOT NULL,"
        "  is_locked INTEGER DEFAULT 0,"
        "  upload_status INTEGER DEFAULT 0,"
        "  retry_count INTEGER DEFAULT 0"
        ");"
        "CREATE INDEX IF NOT EXISTS idx_clips_status ON clips(upload_status, is_locked, start_epoch);"
        "CREATE TABLE IF NOT EXISTS daily_quota ("
        "  day_key TEXT PRIMARY KEY,"
        "  metered_bytes INTEGER DEFAULT 0,"
        "  home_bytes INTEGER DEFAULT 0"
        ");";
    sqlite3_exec(_db, schemaSQL, NULL, NULL, NULL);
}

- (NSString *)loopDirectory { return _loopDir; }
- (NSString *)lockedDirectory { return _lockedDir; }
- (NSString *)tempUploadDirectory { return _tempDir; }

- (NSString *)todayKey {
    return [_dayKeyFmt stringFromDate:[NSDate date]];
}

- (int64_t)folderBytesAtPath:(NSString *)dirPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:dirPath error:nil];
    int64_t total = 0;
    for (NSString *name in items) {
        if (![name hasSuffix:@".mp4"] && ![name hasSuffix:@".json"]) continue;
        NSString *p = [dirPath stringByAppendingPathComponent:name];
        NSDictionary *attrs = [fm attributesOfItemAtPath:p error:nil];
        total += [attrs fileSize];
    }
    return total;
}

- (int64_t)freeDiskBytes {
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfFileSystemForPath:_loopDir error:nil];
    NSNumber *freeNum = attrs[NSFileSystemFreeSize];
    return freeNum ? freeNum.longLongValue : 0;
}

- (double)freeDiskSpaceGB {
    return (double)[self freeDiskBytes] / (1024.0 * 1024.0 * 1024.0);
}

- (double)loopFolderSizeGB {
    return (double)[self folderBytesAtPath:_loopDir] / (1024.0 * 1024.0 * 1024.0);
}

- (double)lockedFolderSizeGB {
    return (double)[self folderBytesAtPath:_lockedDir] / (1024.0 * 1024.0 * 1024.0);
}

- (NSString *)allocateNextClipPathForStartDate:(NSDate *)startDate {
    [self ensureSafeFreeSpace];
    NSString *stamp = [_fileDateFmt stringFromDate:(startDate ?: [NSDate date])];
    NSString *fname = [NSString stringWithFormat:@"CD6_%@.mp4", stamp];
    return [_loopDir stringByAppendingPathComponent:fname];
}

- (void)ensureSafeFreeSpace {
    dispatch_sync(_ioQueue, ^{
        DashcamConfig *cfg = [DashcamConfig sharedConfig];
        int64_t minFreeBytes   = (int64_t)(cfg.minFreeSpaceGB * 1024.0 * 1024.0 * 1024.0);
        int64_t targetFree     = minFreeBytes + (int64_t)(512.0 * 1024.0 * 1024.0); // +512 MB hysteresis
        int64_t maxLoopBytes   = (int64_t)(cfg.maxLoopStorageGB * 1024.0 * 1024.0 * 1024.0);
        int64_t maxLockedBytes = (int64_t)(cfg.maxLockedStorageGB * 1024.0 * 1024.0 * 1024.0);

        NSFileManager *fm = [NSFileManager defaultManager];

        // 1. Enforce LoopClips FIFO (Uploaded clips first, then oldest pending clips)
        int guard = 0;
        while (guard++ < 40 && ([self freeDiskBytes] < minFreeBytes || [self folderBytesAtPath:self->_loopDir] > maxLoopBytes)) {
            NSString *victimPath = [self findOldestDeletableLoopPathPreferUploaded:YES];
            if (!victimPath) {
                victimPath = [self findOldestDeletableLoopPathPreferUploaded:NO];
            }
            if (!victimPath) {
                // Fallback: scan directory directly in case orphan files exist
                NSArray<NSString *> *files = [[fm contentsOfDirectoryAtPath:self->_loopDir error:nil]
                                              sortedArrayUsingSelector:@selector(compare:)];
                for (NSString *f in files) {
                    if ([f hasSuffix:@".mp4"]) {
                        victimPath = [self->_loopDir stringByAppendingPathComponent:f];
                        break;
                    }
                }
            }
            if (!victimPath) break;

            [fm removeItemAtPath:victimPath error:nil];
            [self deleteClipRecordByPathLocked:victimPath];

            if ([self freeDiskBytes] >= targetFree && [self folderBytesAtPath:self->_loopDir] <= maxLoopBytes) {
                break;
            }
        }

        // 2. Enforce LockedClips cap (only if LockedClips exceeds maxLockedStorageGB)
        guard = 0;
        while (guard++ < 15 && [self folderBytesAtPath:self->_lockedDir] > maxLockedBytes) {
            NSArray<NSString *> *files = [[fm contentsOfDirectoryAtPath:self->_lockedDir error:nil]
                                          sortedArrayUsingSelector:@selector(compare:)];
            NSString *oldest = nil;
            for (NSString *f in files) {
                if ([f hasSuffix:@".mp4"]) {
                    oldest = [self->_lockedDir stringByAppendingPathComponent:f];
                    break;
                }
            }
            if (!oldest) break;
            [fm removeItemAtPath:oldest error:nil];
            [self deleteClipRecordByPathLocked:oldest];
        }
    });
}

- (NSString *)findOldestDeletableLoopPathPreferUploaded:(BOOL)preferUploaded {
    if (!_db) return nil;
    const char *sql = preferUploaded
        ? "SELECT full_path FROM clips WHERE is_locked = 0 AND upload_status = 2 ORDER BY start_epoch ASC LIMIT 1;"
        : "SELECT full_path FROM clips WHERE is_locked = 0 AND upload_status != 1 ORDER BY start_epoch ASC LIMIT 1;";
    sqlite3_stmt *stmt = NULL;
    NSString *result = nil;
    if (sqlite3_prepare_v2(_db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            const unsigned char *txt = sqlite3_column_text(stmt, 0);
            if (txt) result = [NSString stringWithUTF8String:(const char *)txt];
        }
        sqlite3_finalize(stmt);
    }
    return result;
}

- (void)deleteClipRecordByPathLocked:(NSString *)fullPath {
    if (!_db || !fullPath) return;
    const char *sql = "DELETE FROM clips WHERE full_path = ?;";
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(_db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, fullPath.UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_step(stmt);
        sqlite3_finalize(stmt);
    }
}

- (DashcamClipRecord *)registerCompletedClipAtPath:(NSString *)filePath
                                        startEpoch:(double)startEpoch
                                       durationSec:(NSInteger)durationSec
                                           caption:(NSString *)caption
                                          isLocked:(BOOL)isLocked {
    if (!filePath.length) return nil;
    __block DashcamClipRecord *rec = nil;
    dispatch_sync(_ioQueue, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:filePath]) return;

        NSString *finalPath = filePath;
        if (isLocked && ![filePath hasPrefix:self->_lockedDir]) {
            NSString *base = [filePath.lastPathComponent stringByReplacingOccurrencesOfString:@".mp4" withString:@"_LOCKED.mp4"];
            NSString *dst  = [self->_lockedDir stringByAppendingPathComponent:base];
            NSError *mvErr = nil;
            if ([fm moveItemAtPath:filePath toPath:dst error:&mvErr]) {
                finalPath = dst;
            }
        }

        NSDictionary *attrs = [fm attributesOfItemAtPath:finalPath error:nil];
        int64_t sizeBytes = [attrs fileSize];
        if (sizeBytes < 4096) {
            // Corrupt/empty 0-byte clip -> discard immediately
            [fm removeItemAtPath:finalPath error:nil];
            return;
        }

        if (!self->_db) return;
        const char *sql =
            "INSERT OR REPLACE INTO clips "
            "(filename, full_path, caption, start_epoch, duration_sec, size_bytes, is_locked, upload_status, retry_count) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0);";
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(self->_db, sql, -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_text(stmt, 1, finalPath.lastPathComponent.UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(stmt, 2, finalPath.UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(stmt, 3, (caption ?: @"").UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_bind_double(stmt, 4, startEpoch);
            sqlite3_bind_int(stmt, 5, (int)durationSec);
            sqlite3_bind_int64(stmt, 6, sizeBytes);
            sqlite3_bind_int(stmt, 7, isLocked ? 1 : 0);
            if (sqlite3_step(stmt) == SQLITE_DONE) {
                rec = [[DashcamClipRecord alloc] init];
                rec.clipId       = sqlite3_last_insert_rowid(self->_db);
                rec.filename     = finalPath.lastPathComponent;
                rec.fullPath     = finalPath;
                rec.caption      = caption ?: @"";
                rec.startEpoch   = startEpoch;
                rec.durationSec  = durationSec;
                rec.sizeBytes    = sizeBytes;
                rec.isLocked     = isLocked;
                rec.uploadStatus = ClipUploadPending;
            }
            sqlite3_finalize(stmt);
        }
    });
    return rec;
}

- (BOOL)promoteClipToLockedByPath:(NSString *)filePath {
    if (!filePath.length) return NO;
    __block BOOL ok = NO;
    dispatch_sync(_ioQueue, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:filePath]) return;
        NSString *dst = filePath;
        if (![filePath hasPrefix:self->_lockedDir]) {
            NSString *base = [filePath.lastPathComponent stringByReplacingOccurrencesOfString:@".mp4" withString:@"_LOCKED.mp4"];
            dst = [self->_lockedDir stringByAppendingPathComponent:base];
            if (![fm moveItemAtPath:filePath toPath:dst error:nil]) {
                return;
            }
        }
        if (self->_db) {
            const char *sql = "UPDATE clips SET is_locked = 1, full_path = ?, filename = ?, caption = '[LOCKED] ' || caption WHERE full_path = ?;";
            sqlite3_stmt *stmt = NULL;
            if (sqlite3_prepare_v2(self->_db, sql, -1, &stmt, NULL) == SQLITE_OK) {
                sqlite3_bind_text(stmt, 1, dst.UTF8String, -1, SQLITE_TRANSIENT);
                sqlite3_bind_text(stmt, 2, dst.lastPathComponent.UTF8String, -1, SQLITE_TRANSIENT);
                sqlite3_bind_text(stmt, 3, filePath.UTF8String, -1, SQLITE_TRANSIENT);
                ok = (sqlite3_step(stmt) == SQLITE_DONE);
                sqlite3_finalize(stmt);
            }
        }
    });
    return ok;
}

- (BOOL)lockMostRecentLoopClip {
    __block NSString *latestPath = nil;
    dispatch_sync(_ioQueue, ^{
        if (!self->_db) return;
        const char *sql = "SELECT full_path FROM clips WHERE is_locked = 0 ORDER BY start_epoch DESC LIMIT 1;";
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(self->_db, sql, -1, &stmt, NULL) == SQLITE_OK) {
            if (sqlite3_step(stmt) == SQLITE_ROW) {
                const unsigned char *txt = sqlite3_column_text(stmt, 0);
                if (txt) latestPath = [NSString stringWithUTF8String:(const char *)txt];
            }
            sqlite3_finalize(stmt);
        }
    });
    return latestPath ? [self promoteClipToLockedByPath:latestPath] : NO;
}

- (DashcamClipRecord *)nextPendingClipAllowRegular:(BOOL)allowRegular {
    __block DashcamClipRecord *rec = nil;
    dispatch_sync(_ioQueue, ^{
        if (!self->_db) return;
        // Priority: LOCKED clips first (newest first), then regular clips (oldest first for chronological Telegram timeline)
        const char *sql = allowRegular
            ? "SELECT id, filename, full_path, caption, start_epoch, duration_sec, size_bytes, is_locked, upload_status, retry_count "
              "FROM clips WHERE upload_status IN (0, 3) AND retry_count < 8 "
              "ORDER BY is_locked DESC, CASE WHEN is_locked=1 THEN -start_epoch ELSE start_epoch END ASC LIMIT 1;"
            : "SELECT id, filename, full_path, caption, start_epoch, duration_sec, size_bytes, is_locked, upload_status, retry_count "
              "FROM clips WHERE is_locked = 1 AND upload_status IN (0, 3) AND retry_count < 12 "
              "ORDER BY start_epoch DESC LIMIT 1;";
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(self->_db, sql, -1, &stmt, NULL) == SQLITE_OK) {
            if (sqlite3_step(stmt) == SQLITE_ROW) {
                rec = [[DashcamClipRecord alloc] init];
                rec.clipId       = sqlite3_column_int64(stmt, 0);
                const unsigned char *fn = sqlite3_column_text(stmt, 1);
                const unsigned char *fp = sqlite3_column_text(stmt, 2);
                const unsigned char *cp = sqlite3_column_text(stmt, 3);
                rec.filename     = fn ? [NSString stringWithUTF8String:(const char *)fn] : @"";
                rec.fullPath     = fp ? [NSString stringWithUTF8String:(const char *)fp] : @"";
                rec.caption      = cp ? [NSString stringWithUTF8String:(const char *)cp] : @"";
                rec.startEpoch   = sqlite3_column_double(stmt, 4);
                rec.durationSec  = sqlite3_column_int(stmt, 5);
                rec.sizeBytes    = sqlite3_column_int64(stmt, 6);
                rec.isLocked     = (sqlite3_column_int(stmt, 7) != 0);
                rec.uploadStatus = (ClipUploadStatus)sqlite3_column_int(stmt, 8);
                rec.retryCount   = sqlite3_column_int(stmt, 9);
            }
            sqlite3_finalize(stmt);
        }
        // If file disappeared on disk, purge DB row and return nil
        if (rec && ![[NSFileManager defaultManager] fileExistsAtPath:rec.fullPath]) {
            [self deleteClipRecordByPathLocked:rec.fullPath];
            rec = nil;
        }
    });
    return rec;
}

- (void)markClip:(int64_t)clipId status:(ClipUploadStatus)status incrementRetry:(BOOL)incRetry {
    dispatch_sync(_ioQueue, ^{
        if (!self->_db) return;
        const char *sql = incRetry
            ? "UPDATE clips SET upload_status = ?, retry_count = retry_count + 1 WHERE id = ?;"
            : "UPDATE clips SET upload_status = ? WHERE id = ?;";
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(self->_db, sql, -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_int(stmt, 1, (int)status);
            sqlite3_bind_int64(stmt, 2, clipId);
            sqlite3_step(stmt);
            sqlite3_finalize(stmt);
        }
    });
}

- (void)resetStuckUploadingClips {
    dispatch_sync(_ioQueue, ^{
        if (!self->_db) return;
        sqlite3_exec(self->_db, "UPDATE clips SET upload_status = 0 WHERE upload_status = 1;", NULL, NULL, NULL);
    });
}

- (NSInteger)pendingUploadCount {
    __block NSInteger cnt = 0;
    dispatch_sync(_ioQueue, ^{
        if (!self->_db) return;
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(self->_db, "SELECT COUNT(*) FROM clips WHERE upload_status IN (0, 1, 3) AND retry_count < 8;", -1, &stmt, NULL) == SQLITE_OK) {
            if (sqlite3_step(stmt) == SQLITE_ROW) cnt = sqlite3_column_int(stmt, 0);
            sqlite3_finalize(stmt);
        }
    });
    return cnt;
}

- (NSInteger)pendingLockedCount {
    __block NSInteger cnt = 0;
    dispatch_sync(_ioQueue, ^{
        if (!self->_db) return;
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(self->_db, "SELECT COUNT(*) FROM clips WHERE is_locked = 1 AND upload_status IN (0, 1, 3);", -1, &stmt, NULL) == SQLITE_OK) {
            if (sqlite3_step(stmt) == SQLITE_ROW) cnt = sqlite3_column_int(stmt, 0);
            sqlite3_finalize(stmt);
        }
    });
    return cnt;
}

- (void)addUploadedBytes:(int64_t)bytes isMetered:(BOOL)isMetered {
    if (bytes <= 0) return;
    dispatch_sync(_ioQueue, ^{
        if (!self->_db) return;
        NSString *day = [self todayKey];
        const char *ins = "INSERT OR IGNORE INTO daily_quota (day_key, metered_bytes, home_bytes) VALUES (?, 0, 0);";
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(self->_db, ins, -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_text(stmt, 1, day.UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_step(stmt);
            sqlite3_finalize(stmt);
        }
        const char *upd = isMetered
            ? "UPDATE daily_quota SET metered_bytes = metered_bytes + ? WHERE day_key = ?;"
            : "UPDATE daily_quota SET home_bytes = home_bytes + ? WHERE day_key = ?;";
        if (sqlite3_prepare_v2(self->_db, upd, -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_int64(stmt, 1, bytes);
            sqlite3_bind_text(stmt, 2, day.UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_step(stmt);
            sqlite3_finalize(stmt);
        }
    });
}

- (int64_t)todayMeteredBytesSent {
    __block int64_t val = 0;
    dispatch_sync(_ioQueue, ^{
        if (!self->_db) return;
        NSString *day = [self todayKey];
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(self->_db, "SELECT metered_bytes FROM daily_quota WHERE day_key = ?;", -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_text(stmt, 1, day.UTF8String, -1, SQLITE_TRANSIENT);
            if (sqlite3_step(stmt) == SQLITE_ROW) val = sqlite3_column_int64(stmt, 0);
            sqlite3_finalize(stmt);
        }
    });
    return val;
}

- (int64_t)todayHomeBytesSent {
    __block int64_t val = 0;
    dispatch_sync(_ioQueue, ^{
        if (!self->_db) return;
        NSString *day = [self todayKey];
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(self->_db, "SELECT home_bytes FROM daily_quota WHERE day_key = ?;", -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_text(stmt, 1, day.UTF8String, -1, SQLITE_TRANSIENT);
            if (sqlite3_step(stmt) == SQLITE_ROW) val = sqlite3_column_int64(stmt, 0);
            sqlite3_finalize(stmt);
        }
    });
    return val;
}

- (void)resetTodayQuota {
    dispatch_sync(_ioQueue, ^{
        if (!self->_db) return;
        NSString *day = [self todayKey];
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(self->_db, "UPDATE daily_quota SET metered_bytes = 0 WHERE day_key = ?;", -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_text(stmt, 1, day.UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_step(stmt);
            sqlite3_finalize(stmt);
        }
    });
}

@end
