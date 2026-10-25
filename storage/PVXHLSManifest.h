#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PVXHLSKey : NSObject
@property(nonatomic,copy) NSString *method;
@property(nonatomic,copy) NSString *URI;
@property(nonatomic,copy) NSString *IV;
@property(nonatomic,copy) NSString *keyformat;
@end

@interface PVXHLSMap : NSObject
@property(nonatomic,copy) NSString *URI;
@property(nonatomic,copy) NSString *byterange;
@end

@interface PVXHLSSegment : NSObject
@property(nonatomic,copy) NSString *URI;
@property(nonatomic) double duration;
@property(nonatomic) long long sequence;
@property(nonatomic,copy) NSString *title;
@property(nonatomic,copy) NSString *byterange;
@property(nonatomic,strong,nullable) PVXHLSKey *key;
@property(nonatomic,strong,nullable) PVXHLSMap *map;
@property(nonatomic) BOOL discontinuity;
@property(nonatomic) BOOL gap;
@end

@interface PVXHLSVariant : NSObject
@property(nonatomic,copy) NSString *URI;
@property(nonatomic) long long bandwidth;
@property(nonatomic) long long averageBandwidth;
@property(nonatomic) NSInteger width;
@property(nonatomic) NSInteger height;
@property(nonatomic,copy) NSString *codecs;
@property(nonatomic,copy) NSString *audioGroup;
@end

@interface PVXHLSEntry : NSObject
@property(nonatomic,copy) NSString *URI;
@property(nonatomic,copy) NSString *groupID;
@property(nonatomic,copy) NSString *name;
@property(nonatomic,copy) NSString *language;
@property(nonatomic) BOOL isDefault;
@property(nonatomic) BOOL autoselect;
@end

@interface PVXHLSManifest : NSObject
@property(nonatomic,readonly) BOOL master;
@property(nonatomic,readonly) BOOL endList;
@property(nonatomic,readonly) NSInteger version;
@property(nonatomic,readonly) long long mediaSequence;
@property(nonatomic,readonly) double targetDuration;
@property(nonatomic,copy,readonly) NSArray<PVXHLSVariant *> *variants;
@property(nonatomic,copy,readonly) NSArray<PVXHLSEntry *> *audioRenditions;
@property(nonatomic,copy,readonly) NSArray<PVXHLSSegment *> *segments;
@property(nonatomic,copy,readonly) NSURL *baseURL;
@property(nonatomic,copy,readonly) NSString *sourceText;
+ (nullable instancetype)parseData:(NSData *)data baseURL:(NSURL *)baseURL error:(NSError **)error;
+ (nullable instancetype)parseText:(NSString *)text baseURL:(NSURL *)baseURL error:(NSError **)error;
- (nullable PVXHLSVariant *)bestVariant;
- (nullable PVXHLSEntry *)defaultAudioForGroup:(NSString *)groupID;
- (NSString *)localizedTextWithSegmentURLs:(NSDictionary<NSString *,NSString *> *)localURLs;
- (NSString *)localizedTextWithSegments:(NSArray<PVXHLSSegment *> *)segments localURLs:(NSDictionary<NSString *,NSString *> *)localURLs;
@end

NS_ASSUME_NONNULL_END
