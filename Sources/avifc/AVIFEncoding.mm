//
//  AVIFEncoder.m
//  
//
//  Created by Radzivon Bartoshyk on 01/05/2022.
//

#import <Foundation/Foundation.h>
#if __has_include(<libavif/avif.h>)
#import <libavif/avif.h>
#else
#import "avif/avif.h"
#endif
#import <Accelerate/Accelerate.h>
#include "AVIFEncoding.h"
#include "PlatformImage.h"
#include <vector>

static void releaseSharedEncoder(avifEncoder* encoder) {
    avifEncoderDestroy(encoder);
}

static void releaseSharedEncoderImage(avifImage* image) {
    avifImageDestroy(image);
}

static void releaseSharedPixels(unsigned char * pixels) {
    free(pixels);
}

@implementation AVIFEncoding {
}

- (nullable NSData *)encodeImage:(nonnull Image *)platformImage
                           speed:(NSInteger)speed
                           quality:(double)quality error:(NSError * _Nullable *_Nullable)error {
    unsigned char * rgbPixels = [platformImage rgbaPixels];
    if (!rgbPixels) {
        *error = [[NSError alloc] initWithDomain:@"AVIFEncoder"
                                            code:500
                                        userInfo:@{ NSLocalizedDescriptionKey: @"Fetching image pixels has failed" }];
        return nil;
    }
    std::shared_ptr<unsigned char> rgba(rgbPixels, releaseSharedPixels);
#if TARGET_OS_OSX
    int width = [platformImage size].width;
    int height = [platformImage size].height;
#else
    int width = [platformImage size].width * [platformImage scale];
    int height = [platformImage size].height * [platformImage scale];
#endif
    avifRGBImage rgb;
    auto img = avifImageCreate(width, height, (uint32_t)8, AVIF_PIXEL_FORMAT_YUV420);
    if (!img) {
        *error = [[NSError alloc] initWithDomain:@"AVIFEncoder"
                                            code:500
                                        userInfo:@{ NSLocalizedDescriptionKey: @"Memory allocation for image has failed" }];
        return nil;
    }
    std::shared_ptr<avifImage> image(img, releaseSharedEncoderImage);
    avifRGBImageSetDefaults(&rgb, image.get());
    avifRGBImageAllocatePixels(&rgb);
    rgb.alphaPremultiplied = true;
    memcpy(rgb.pixels, rgba.get(), rgb.rowBytes * image->height);

    rgba.reset();
    avifResult convertResult = avifImageRGBToYUV(image.get(), &rgb);
    if (convertResult != AVIF_RESULT_OK) {
        avifRGBImageFreePixels(&rgb);
        *error = [[NSError alloc] initWithDomain:@"AVIFEncoder" code:500 userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat: @"convert to YUV failed with result: %s", avifResultToString(convertResult)] }];
        return nil;
    }

    auto dec = avifEncoderCreate();
    if (!dec) {
        avifRGBImageFreePixels(&rgb);
        *error = [[NSError alloc] initWithDomain:@"AVIFEncoder"
                                            code:500
                                        userInfo:@{ NSLocalizedDescriptionKey: @"Memory allocation for encoder has failed" }];
        return nil;
    }
    std::shared_ptr<avifEncoder> encoder(dec, releaseSharedEncoder);
    encoder->maxThreads = 4;
    if (quality != 1.0) {
        int rescaledQuality = AVIF_QUANTIZER_WORST_QUALITY - (int)(quality * AVIF_QUANTIZER_WORST_QUALITY);
        encoder->minQuantizer = rescaledQuality;
        encoder->maxQuantizer = rescaledQuality;
    }
    if (speed != -1) {
        encoder->speed = (int)MAX(MIN(speed, AVIF_SPEED_FASTEST), AVIF_SPEED_SLOWEST);
    }
    auto encoderPtr = encoder.get();
    avifResult addImageResult = avifEncoderAddImage(encoderPtr, image.get(), 1, AVIF_ADD_IMAGE_FLAG_SINGLE);
    if (addImageResult != AVIF_RESULT_OK) {
        avifRGBImageFreePixels(&rgb);
        encoder.reset();
        *error = [[NSError alloc] initWithDomain:@"AVIFEncoder" code:500 userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat: @"add image failed with result: %s", avifResultToString(addImageResult)] }];
        return nil;
    }
    
    avifRWData avifOutput = AVIF_DATA_EMPTY;
    avifResult finishResult = avifEncoderFinish(encoderPtr, &avifOutput);
    if (finishResult != AVIF_RESULT_OK) {
        avifRGBImageFreePixels(&rgb);
        encoder.reset();
        *error = [[NSError alloc] initWithDomain:@"AVIFEncoder" code:500 userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat: @"encoding failed with result: %s", avifResultToString(addImageResult)] }];
        return nil;
    }
    
    NSData *result = [[NSData alloc] initWithBytes:avifOutput.data length:avifOutput.size];
    
    avifRWDataFree(&avifOutput);
    avifRGBImageFreePixels(&rgb);
    encoder.reset();
    
    return result;
}

@end
