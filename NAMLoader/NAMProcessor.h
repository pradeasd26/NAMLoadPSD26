#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

/// Jembatan Objective-C++ ke NeuralAmpModelerCore.
@interface NAMProcessor : NSObject
@property (atomic) float inputGainDb;   // trim input: -12...+24
@property (atomic) float masterGainDb;  // master: -60...+12
@property (atomic) BOOL muted;          // dipakai pelindung feedback
@property (atomic) BOOL irEnabled;
@property (readonly) BOOL hasModel;

- (BOOL)loadModelAtPath:(NSString *)path error:(NSError **)error;
- (void)unloadModel;
- (void)setImpulse:(const float *)ir length:(int)n; // IR mono, sudah di sample rate engine
- (void)clearImpulse;
- (void)prepareWithSampleRate:(double)sampleRate maxFrames:(int)maxFrames;
- (void)pushInput:(const float *)samples frames:(int)frames;   // thread audio
- (void)renderOutput:(float *)out frames:(int)frames;          // thread audio
- (float)takeInputPeak;   // peak linear sejak panggilan terakhir
- (float)takeOutputPeak;
@end
NS_ASSUME_NONNULL_END
