#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
NS_ASSUME_NONNULL_BEGIN

/// Jembatan Objective-C++ ke mesin sinyal 12 slot + NeuralAmpModelerCore.
@interface NAMProcessor : NSObject
@property (atomic) float inputGainDb;   // trim input: -12...+24
@property (atomic) float masterGainDb;  // master: -60...+12
@property (atomic) BOOL muted;          // pelindung feedback / tuner
@property (atomic) BOOL dualMode;       // NO = 12 slot serial, YES = jalur A (posisi 1-6) paralel jalur B (7-12)
@property (atomic) float balance;       // 0 = hanya jalur A ... 1 = hanya jalur B
@property (atomic) float spread;        // 0 = mono ... 1 = A di kiri, B di kanan
@property (atomic) int inputChannel;    // -1 = otomatis, 0...7 = kanal tertentu, 100 = gabungan kanal 1+2
@property (atomic) float looperLevel;   // 0...1.5

- (void)prepareWithSampleRate:(double)sampleRate maxFrames:(int)maxFrames;
- (void)configureSlot:(int)slot type:(int)type;                     // type: lihat BlockType di Swift
- (void)setParamForSlot:(int)slot index:(int)index value:(float)value;
- (void)setEnabledForSlot:(int)slot enabled:(BOOL)enabled;
- (void)setOrder:(const int *)order;                                // 12 nomor slot = urutan proses
- (BOOL)loadModelAtPath:(NSString *)path forSlot:(int)slot error:(NSError **)error;
- (void)setImpulse:(const float *)ir length:(int)n forSlot:(int)slot; // IR mono, sudah di sample rate engine

- (void)pushInputList:(const AudioBufferList *)list frames:(int)frames; // thread audio
- (void)renderLeft:(float *)left right:(float *)right frames:(int)frames; // thread audio

- (float)takeInputPeak;
- (float)takeOutputPeak;
- (float)channelPeak:(int)channel;      // puncak per kanal input (0...7), direset tiap dibaca
- (float)dspLoad;                       // 0...1+ = waktu render / durasi buffer
- (float)detectPitch;                   // Hz, 0 = tidak ada nada
- (void)spectrum:(float *)bands count:(int)count; // 0...1 per pita (40 Hz - 16 kHz, skala log)

- (void)looperAllocateSeconds:(float)seconds;
- (void)looperCommand:(int)cmd;         // 1 utama, 2 stop, 3 hapus
- (void)looperState:(int *)state length:(int *)length position:(int *)position;
@end
NS_ASSUME_NONNULL_END
