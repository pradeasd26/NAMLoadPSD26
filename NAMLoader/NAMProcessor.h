#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

/// Jembatan Objective-C++ ke mesin sinyal 12 slot + NeuralAmpModelerCore.
@interface NAMProcessor : NSObject
@property (atomic) float inputGainDb;   // trim input: -12...+24
@property (atomic) float masterGainDb;  // master: -60...+12
@property (atomic) BOOL muted;          // dipakai pelindung feedback
@property (atomic) BOOL dualMode;       // NO = 12 slot serial, YES = jalur A (1-6) paralel jalur B (7-12)
@property (atomic) float balance;       // 0 = hanya jalur A ... 1 = hanya jalur B
@property (atomic) float spread;        // 0 = mono ... 1 = A di kiri, B di kanan

- (void)prepareWithSampleRate:(double)sampleRate maxFrames:(int)maxFrames;
- (void)configureSlot:(int)slot type:(int)type;                     // type: lihat BlockType di Swift
- (void)setParamForSlot:(int)slot index:(int)index value:(float)value;
- (void)setEnabledForSlot:(int)slot enabled:(BOOL)enabled;
- (BOOL)loadModelAtPath:(NSString *)path forSlot:(int)slot error:(NSError **)error;
- (void)setImpulse:(const float *)ir length:(int)n forSlot:(int)slot; // IR mono, sudah di sample rate engine
- (void)pushInput:(const float *)samples frames:(int)frames;        // thread audio
- (void)renderLeft:(float *)left right:(float *)right frames:(int)frames; // thread audio
- (float)takeInputPeak;
- (float)takeOutputPeak;
@end
NS_ASSUME_NONNULL_END
