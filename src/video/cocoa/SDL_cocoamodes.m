/*
  Simple DirectMedia Layer
  Copyright (C) 1997-2022 Sam Lantinga <slouken@libsdl.org>

  This software is provided 'as-is', without any express or implied
  warranty.  In no event will the authors be held liable for any damages
  arising from the use of this software.

  Permission is granted to anyone to use this software for any purpose,
  including commercial applications, and to alter it and redistribute it
  freely, subject to the following restrictions:

  1. The origin of this software must not be misrepresented; you must not
     claim that you wrote the original software. If you use this software
     in a product, an acknowledgment in the product documentation would be
     appreciated but is not required.
  2. Altered source versions must be plainly marked as such, and must not be
     misrepresented as being the original software.
  3. This notice may not be removed or altered from any source distribution.
*/
#include "../../SDL_internal.h"

#if SDL_VIDEO_DRIVER_COCOA

#include "SDL_cocoavideo.h"

/* We need this for IODisplayCreateInfoDictionary and kIODisplayOnlyPreferredName */
#include <IOKit/graphics/IOGraphicsLib.h>

/* We need this for CVDisplayLinkGetNominalOutputVideoRefreshPeriod */
#include <CoreVideo/CVBase.h>
#include <CoreVideo/CVDisplayLink.h>

/* we need this for ShowMenuBar() and HideMenuBar(). */
#include <Carbon/Carbon.h>

/* This gets us MAC_OS_X_VERSION_MIN_REQUIRED... */
#include <AvailabilityMacros.h>


static void
Cocoa_ToggleMenuBar(const BOOL show)
{
    /* !!! FIXME: keep an eye on this.
     * ShowMenuBar/HideMenuBar is officially unavailable for 64-bit binaries.
     *  It happens to work, as of 10.7, but we're going to see if
     *  we can just simply do without it on newer OSes...
     */
#if (MAC_OS_X_VERSION_MIN_REQUIRED < 1070) && !defined(__LP64__)
    if (show) {
        ShowMenuBar();
    } else {
        HideMenuBar();
    }
#endif
}

#define FORCE_OLD_API 1

#if FORCE_OLD_API
#undef MAC_OS_X_VERSION_MIN_REQUIRED
#define MAC_OS_X_VERSION_MIN_REQUIRED 1050
#endif

static BOOL
IS_SNOW_LEOPARD_OR_LATER()
{
#if FORCE_OLD_API
    return NO;
#else
    return floor(NSAppKitVersionNumber) > NSAppKitVersionNumber10_5;
#endif
}

static int
CG_SetError(const char *prefix, CGDisplayErr result)
{
    const char *error;

    switch (result) {
    case kCGErrorFailure:
        error = "kCGErrorFailure";
        break;
    case kCGErrorIllegalArgument:
        error = "kCGErrorIllegalArgument";
        break;
    case kCGErrorInvalidConnection:
        error = "kCGErrorInvalidConnection";
        break;
    case kCGErrorInvalidContext:
        error = "kCGErrorInvalidContext";
        break;
    case kCGErrorCannotComplete:
        error = "kCGErrorCannotComplete";
        break;
    case kCGErrorNotImplemented:
        error = "kCGErrorNotImplemented";
        break;
    case kCGErrorRangeCheck:
        error = "kCGErrorRangeCheck";
        break;
    case kCGErrorTypeCheck:
        error = "kCGErrorTypeCheck";
        break;
    case kCGErrorInvalidOperation:
        error = "kCGErrorInvalidOperation";
        break;
    case kCGErrorNoneAvailable:
        error = "kCGErrorNoneAvailable";
        break;
    default:
        error = "Unknown Error";
        break;
    }
    return SDL_SetError("%s: %s", prefix, error);
}

static int
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1060 && !defined(__ppc__)
GetDisplayModeRefreshRate(CGDisplayModeRef vidmode, CVDisplayLinkRef link)
#else
GetDisplayModeRefreshRate(const void *moderef, CVDisplayLinkRef link)
#endif
{
    int refreshRate = (int) (CGDisplayModeGetRefreshRate(vidmode) + 0.5);

    /* CGDisplayModeGetRefreshRate can return 0 (eg for built-in displays). */
    if (refreshRate == 0 && link != NULL) {
        CVTime time = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(link);
        if ((time.flags & kCVTimeIsIndefinite) == 0 && time.timeValue != 0) {
            refreshRate = (int) ((time.timeScale / (double) time.timeValue) + 0.5);
        }
    }

    return refreshRate;
}

static SDL_bool

HasValidDisplayModeFlags(CGDisplayModeRef vidmode)
#else
HasValidDisplayModeFlags(const void *moderef)
#endif
{
    uint32_t ioflags = CGDisplayModeGetIOFlags(vidmode);

    /* Filter out modes which have flags that we don't want. */
    if (ioflags & (kDisplayModeNeverShowFlag | kDisplayModeNotGraphicsQualityFlag)) {
        return SDL_FALSE;
    }

    /* Filter out modes which don't have flags that we want. */
    if (!(ioflags & kDisplayModeValidFlag) || !(ioflags & kDisplayModeSafeFlag)) {
        return SDL_FALSE;
    }

    return SDL_TRUE;
}

static Uint32
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1060 && !defined(__ppc__)
GetDisplayModePixelFormat(CGDisplayModeRef vidmode)
{
    /* This API is deprecated in 10.11 with no good replacement (as of 10.15). */
    CFStringRef fmt = CGDisplayModeCopyPixelEncoding(vidmode);
    Uint32 pixelformat = SDL_PIXELFORMAT_UNKNOWN;

    if (CFStringCompare(fmt, CFSTR(IO32BitDirectPixels),
                        kCFCompareCaseInsensitive) == kCFCompareEqualTo) {
        pixelformat = SDL_PIXELFORMAT_ARGB8888;
    } else if (CFStringCompare(fmt, CFSTR(IO16BitDirectPixels),
                        kCFCompareCaseInsensitive) == kCFCompareEqualTo) {
        pixelformat = SDL_PIXELFORMAT_ARGB1555;
    } else if (CFStringCompare(fmt, CFSTR(kIO30BitDirectPixels),
                        kCFCompareCaseInsensitive) == kCFCompareEqualTo) {
        pixelformat = SDL_PIXELFORMAT_ARGB2101010;
    } else {
        /* ignore 8-bit and such for now. */
    }

    CFRelease(fmt);

    return pixelformat;
}
#else
GetDisplayModePixelFormat(const void *moderef)
    mode->format = SDL_PIXELFORMAT_UNKNOWN;
    switch (bpp) {
    case 16:
        mode->format = SDL_PIXELFORMAT_ARGB1555;
        break;
    case 30:
        mode->format = SDL_PIXELFORMAT_ARGB2101010;
        break;
    case 32:
        mode->format = SDL_PIXELFORMAT_ARGB8888;
        break;
    case 8: /* We don't support palettized modes now */
    default: /* Totally unrecognizable bit depth. */
        SDL_free(data);
        return SDL_FALSE;
    }
#endif

static SDL_bool
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1060 && !defined(__ppc__)
GetDisplayMode(_THIS, CGDisplayModeRef vidmode, SDL_bool vidmodeCurrent, CFArrayRef modelist, CVDisplayLinkRef link, SDL_DisplayMode *mode)
#else
GetDisplayMode(_THIS, const void *moderef, CVDisplayLinkRef link, SDL_DisplayMode *mode)
#endif
{
    SDL_DisplayModeData *data;
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1060 && !defined(__ppc__)
    bool usableForGUI = CGDisplayModeIsUsableForDesktopGUI(vidmode);
    int width = (int) CGDisplayModeGetWidth(vidmode);
    int height = (int) CGDisplayModeGetHeight(vidmode);
    uint32_t ioflags = CGDisplayModeGetIOFlags(vidmode);
    int refreshRate = GetDisplayModeRefreshRate(vidmode, link);
    Uint32 format = GetDisplayModePixelFormat(vidmode);
    bool interlaced = (ioflags & kDisplayModeInterlacedFlag) != 0;
    CFMutableArrayRef modes;

    if (format == SDL_PIXELFORMAT_UNKNOWN) {
        return SDL_FALSE;
    }
#else
    long width = 0;
    long height = 0;
    long bpp = 0;
    long refreshRate = 0;

    data = (SDL_DisplayModeData *) SDL_malloc(sizeof(*data));
    if (!data) {
        return SDL_FALSE;
    }
    data->moderef = moderef;

    if (!IS_SNOW_LEOPARD_OR_LATER()) {
        CFNumberRef number;
        double refresh;
        CFDictionaryRef vidmode = (CFDictionaryRef) moderef;
        number = CFDictionaryGetValue(vidmode, kCGDisplayWidth);
        CFNumberGetValue(number, kCFNumberLongType, &width);
        number = CFDictionaryGetValue(vidmode, kCGDisplayHeight);
        CFNumberGetValue(number, kCFNumberLongType, &height);
        number = CFDictionaryGetValue(vidmode, kCGDisplayBitsPerPixel);
        CFNumberGetValue(number, kCFNumberLongType, &bpp);
        number = CFDictionaryGetValue(vidmode, kCGDisplayRefreshRate);
        CFNumberGetValue(number, kCFNumberDoubleType, &refresh);
        refreshRate = (long) (refresh + 0.5);
    }
#endif

#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1060 && !defined(__ppc__)
    /* Don't fail the current mode based on flags because this could prevent Cocoa_InitModes from
     * succeeding if the current mode lacks certain flags (esp kDisplayModeSafeFlag). */
    if (!vidmodeCurrent && !HasValidDisplayModeFlags(vidmode)) {
        return SDL_FALSE;
    }

    modes = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    CFArrayAppendValue(modes, vidmode);
#endif

    data = (SDL_DisplayModeData *) SDL_malloc(sizeof(*data));
    if (!data) {
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1060 && !defined(__ppc__)
        CFRelease(modes);
#endif
        return SDL_FALSE;
    }
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1060 && !defined(__ppc__)
    data->modes = modes;
    mode->format = format;
#endif
    mode->w = width;
    mode->h = height;
    mode->refresh_rate = refreshRate;
    mode->driverdata = data;
    data->moderef = moderef;
    return SDL_TRUE;
}

static void
Cocoa_ReleaseDisplayMode(_THIS, const void *moderef)
{
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1060 && !defined(__ppc__)
    if (IS_SNOW_LEOPARD_OR_LATER()) {
        CGDisplayModeRelease((CGDisplayModeRef) moderef);  /* NULL is ok */
    }
}

static void
Cocoa_ReleaseDisplayModeList(_THIS, CFArrayRef modelist)
{
    if (IS_SNOW_LEOPARD_OR_LATER()) {
        CFRelease(modelist);  /* NULL is ok */
    }
}

static const char *
Cocoa_GetDisplayName(CGDirectDisplayID displayID)
{
    /* This API is deprecated in 10.9 with no good replacement (as of 10.15). */
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1060 && !defined(__ppc__)
    io_service_t servicePort = CGDisplayIOServicePort(displayID);
#endif
    CFDictionaryRef deviceInfo = IODisplayCreateInfoDictionary(servicePort, kIODisplayOnlyPreferredName);
    NSDictionary *localizedNames = [(NSDictionary *)deviceInfo objectForKey:[NSString stringWithUTF8String:kDisplayProductName]];
    const char* displayName = NULL;

    if ([localizedNames count] > 0) {
        displayName = SDL_strdup([[localizedNames objectForKey:[[localizedNames allKeys] objectAtIndex:0]] UTF8String]);
    }
    CFRelease(deviceInfo);
    return displayName;
}

void
Cocoa_InitModes(_THIS)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    CGDisplayErr result;
    CGDirectDisplayID *displays;
    CGDisplayCount numDisplays;
    SDL_bool isstack;
    int pass, i;

    result = CGGetOnlineDisplayList(0, NULL, &numDisplays);
    if (result != kCGErrorSuccess) {
        CG_SetError("CGGetOnlineDisplayList()", result);
        [pool release];
        return;
    }
    displays = SDL_small_alloc(CGDirectDisplayID, numDisplays, &isstack);
    result = CGGetOnlineDisplayList(numDisplays, displays, &numDisplays);
    if (result != kCGErrorSuccess) {
        CG_SetError("CGGetOnlineDisplayList()", result);
        SDL_small_free(displays, isstack);
        [pool release];
        return;
    }

    /* Pick up the primary display in the first pass, then get the rest */
    for (pass = 0; pass < 2; ++pass) {
        for (i = 0; i < numDisplays; ++i) {
            SDL_VideoDisplay display;
            SDL_DisplayData *displaydata;
            SDL_DisplayMode mode;
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1060 && !defined(__ppc__)
            CGDisplayModeRef moderef = NULL;
#else
            const void *moderef = NULL;
#endif
            CVDisplayLinkRef link = NULL;

            if (pass == 0) {
                if (!CGDisplayIsMain(displays[i])) {
                    continue;
                }
            } else {
                if (CGDisplayIsMain(displays[i])) {
                    continue;
                }
            }

            if (CGDisplayMirrorsDisplay(displays[i]) != kCGNullDirectDisplay) {
                continue;
            }

#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1060 && !defined(__ppc__)
            if (IS_SNOW_LEOPARD_OR_LATER()) {
                moderef = CGDisplayCopyDisplayMode(displays[i]);
            }
#else
            if (!IS_SNOW_LEOPARD_OR_LATER()) {
                moderef = CGDisplayCurrentMode(displays[i]);
            }
#endif

            if (!moderef) {
                continue;
            }

            displaydata = (SDL_DisplayData *) SDL_malloc(sizeof(*displaydata));
            if (!displaydata) {
                Cocoa_ReleaseDisplayMode(_this, moderef);
                continue;
            }
            displaydata->display = displays[i];

            CVDisplayLinkCreateWithCGDisplay(displays[i], &link);

            SDL_zero(display);
            /* this returns a stddup'ed string */
            display.name = (char *)Cocoa_GetDisplayName(displays[i]);
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1060 && !defined(__ppc__)
            if (!GetDisplayMode(_this, moderef, SDL_TRUE, NULL, link, &mode)) {
                CVDisplayLinkRelease(link);
                CGDisplayModeRelease(moderef);
#else
            if (!GetDisplayMode(_this, moderef, link, &mode)) {
                CVDisplayLinkRelease(link);
                Cocoa_ReleaseDisplayMode(_this, moderef);
#endif
                SDL_free(display.name);
                SDL_free(displaydata);
                continue;
            }

            CVDisplayLinkRelease(link);
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1060 && !defined(__ppc__)
            CGDisplayModeRelease(moderef);
#endif

            display.desktop_mode = mode;
            display.current_mode = mode;
            display.driverdata = displaydata;
            SDL_AddVideoDisplay(&display, SDL_FALSE);
            SDL_free(display.name);
        }
    }
    SDL_small_free(displays, isstack);
    [pool release];
}

int
Cocoa_GetDisplayBounds(_THIS, SDL_VideoDisplay * display, SDL_Rect * rect)
{
    SDL_DisplayData *displaydata = (SDL_DisplayData *) display->driverdata;
    CGRect cgrect;

    cgrect = CGDisplayBounds(displaydata->display);
    rect->x = (int)cgrect.origin.x;
    rect->y = (int)cgrect.origin.y;
    rect->w = (int)cgrect.size.width;
    rect->h = (int)cgrect.size.height;
    return 0;
}

int
Cocoa_GetDisplayUsableBounds(_THIS, SDL_VideoDisplay * display, SDL_Rect * rect)
{
    SDL_DisplayData *displaydata = (SDL_DisplayData *) display->driverdata;
    const CGDirectDisplayID cgdisplay = displaydata->display;
    NSArray *screens = [NSScreen screens];
    NSScreen *screen = nil;

    /* !!! FIXME: maybe track the NSScreen in SDL_DisplayData? */
    for (NSScreen *i in screens) {
        const CGDirectDisplayID thisDisplay = (CGDirectDisplayID) [[[i deviceDescription] objectForKey:@"NSScreenNumber"] unsignedIntValue];
        if (thisDisplay == cgdisplay) {
            screen = i;
            break;
        }
    }

    SDL_assert(screen != nil);  /* didn't find it?! */
    if (screen == nil) {
        return -1;
    }

    const NSRect frame = [screen visibleFrame];
    rect->x = (int)frame.origin.x;
    rect->y = (int)(CGDisplayPixelsHigh(kCGDirectMainDisplay) - frame.origin.y - frame.size.height);
    rect->w = (int)frame.size.width;
    rect->h = (int)frame.size.height;

    return 0;
}

int
Cocoa_GetDisplayDPI(_THIS, SDL_VideoDisplay * display, float * ddpi, float * hdpi, float * vdpi)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    const float MM_IN_INCH = 25.4f;

    SDL_DisplayData *data = (SDL_DisplayData *) display->driverdata;

#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1070
    /* we need the backingScaleFactor for Retina displays, which is only exposed through NSScreen, not CGDisplay, afaik, so find our screen... */
    CGFloat scaleFactor = 1.0f;
    NSArray *screens = [NSScreen screens];
    NSSize displayNativeSize;
    displayNativeSize.width = (int) CGDisplayPixelsWide(data->display);
    displayNativeSize.height = (int) CGDisplayPixelsHigh(data->display);
    
    for (NSScreen *screen in screens) {
        const CGDirectDisplayID dpyid = (const CGDirectDisplayID ) [[[screen deviceDescription] objectForKey:@"NSScreenNumber"] unsignedIntValue];
        if (dpyid == data->display) {
            if (floor(NSAppKitVersionNumber) > NSAppKitVersionNumber10_6) {
                // fallback for 10.7
                scaleFactor = [screen backingScaleFactor];
                displayNativeSize.width = displayNativeSize.width * scaleFactor;
                displayNativeSize.height = displayNativeSize.height * scaleFactor;
                break;
            }
        }
    }

    const CGSize displaySize = CGDisplayScreenSize(data->display);
    const int pixelWidth =  displayNativeSize.width;
    const int pixelHeight = displayNativeSize.height;

    if (ddpi) {
        *ddpi = (SDL_ComputeDiagonalDPI(pixelWidth, pixelHeight, displaySize.width / MM_IN_INCH, displaySize.height / MM_IN_INCH)) * scaleFactor;
    }
    if (hdpi) {
        *hdpi = (pixelWidth * MM_IN_INCH / displaySize.width) * scaleFactor;
    }
    if (vdpi) {
        *vdpi = (pixelHeight * MM_IN_INCH / displaySize.height) * scaleFactor;
    }
#else
    CGSize displaySize = CGDisplayScreenSize(data->display);
    int pixelWidth =  (int) CGDisplayPixelsWide(data->display);
    int pixelHeight = (int) CGDisplayPixelsHigh(data->display);

    if (ddpi) {
        *ddpi = (SDL_ComputeDiagonalDPI(pixelWidth, pixelHeight, displaySize.width / MM_IN_INCH, displaySize.height / MM_IN_INCH));
    }
    if (hdpi) {
        *hdpi = (pixelWidth * MM_IN_INCH / displaySize.width);
    }
    if (vdpi) {
        *vdpi = (pixelHeight * MM_IN_INCH / displaySize.height);
    }
#endif
    [pool release];
    return 0;
}

void
Cocoa_GetDisplayModes(_THIS, SDL_VideoDisplay * display)
{
    SDL_DisplayData *data = (SDL_DisplayData *) display->driverdata;
    CVDisplayLinkRef link = NULL;
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1060 && !defined(__ppc__)
    CGDisplayModeRef desktopmoderef;
    SDL_DisplayMode desktopmode;
#endif
    CFArrayRef modes = NULL;
    CFDictionaryRef dict = NULL;

    CVDisplayLinkCreateWithCGDisplay(data->display, &link);

#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1060 && !defined(__ppc__)
    desktopmoderef = CGDisplayCopyDisplayMode(data->display);

    /* CopyAllDisplayModes won't always contain the desktop display mode (if
     * NULL is passed in) - for example on a retina 15" MBP, System Preferences
     * allows choosing 1920x1200 but it's not in the list. AddDisplayMode makes
     * sure there are no duplicates so it's safe to always add the desktop mode
     * even in cases where it is in the CopyAllDisplayModes list.
     */
    if (desktopmoderef && GetDisplayMode(_this, desktopmoderef, SDL_TRUE, NULL, link, &desktopmode)) {
        if (!SDL_AddDisplayMode(display, &desktopmode)) {
            CFRelease(((SDL_DisplayModeData*)desktopmode.driverdata)->modes);
            SDL_free(desktopmode.driverdata);
        }
    }

    CGDisplayModeRelease(desktopmoderef);
#endif

#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1060 && !defined(__ppc__)
    if (IS_SNOW_LEOPARD_OR_LATER()) {
        modes = CGDisplayCopyAllDisplayModes(data->display, NULL);
    }

    if (dict) {
        CFRelease(dict);
    }
#else
    if (!IS_SNOW_LEOPARD_OR_LATER()) {
        modes = CGDisplayAvailableModes(data->display);
    }
#endif

    if (modes) {
        CVDisplayLinkRef link = NULL;
        const CFIndex count = CFArrayGetCount(modes);
        CFIndex i;

        for (i = 0; i < count; i++) {
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1060 && !defined(__ppc__)
            CGDisplayModeRef moderef = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
#else
            const void *moderef = CFArrayGetValueAtIndex(modes, i);
#endif
            SDL_DisplayMode mode;

#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1060 && !defined(__ppc__)
            if (GetDisplayMode(_this, moderef, SDL_FALSE, modes, link, &mode)) {
                if (!SDL_AddDisplayMode(display, &mode)) {
                    CFRelease(((SDL_DisplayModeData*)mode.driverdata)->modes);
#else
            if (GetDisplayMode(_this, moderef, modes, link, &mode)) {
                if (!SDL_AddDisplayMode(display, &mode)) {
#endif
                    SDL_free(mode.driverdata);
                }
            }
        }

        CFRelease(modes);
    }

    CVDisplayLinkRelease(link);
    Cocoa_ReleaseDisplayModeList(_this, modes);
}

static CGError
SetDisplayModeForDisplay(CGDirectDisplayID display, SDL_DisplayModeData *data)
{
    /* SDL_DisplayModeData can contain multiple CGDisplayModes to try (with
     * identical properties), some of which might not work. See GetDisplayMode.
     */
    CGError result = kCGErrorFailure;
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1060 && !defined(__ppc__)
    for (CFIndex i = 0; i < CFArrayGetCount(data->modes); i++) {
        CGDisplayModeRef moderef = (CGDisplayModeRef)CFArrayGetValueAtIndex(data->modes, i);
        result = CGDisplaySetDisplayMode(display, moderef, NULL);
#else
    for (CFIndex i = 0; i < CFArrayGetCount(data->modes); i++) {
        const void *moderef = CFArrayGetValueAtIndex(data->modes, i);
        result = CGDisplaySwitchToMode(display, moderef);
#endif
        if (result == kCGErrorSuccess) {
            /* If this mode works, try it first next time. */
            CFArrayExchangeValuesAtIndices(data->modes, i, 0);
            break;
        }
    }
    return result;
}

int
Cocoa_SetDisplayMode(_THIS, SDL_VideoDisplay * display, SDL_DisplayMode * mode)
{
    SDL_DisplayData *displaydata = (SDL_DisplayData *) display->driverdata;
    SDL_DisplayModeData *data = (SDL_DisplayModeData *) mode->driverdata;
    CGDisplayFadeReservationToken fade_token = kCGDisplayFadeReservationInvalidToken;
    CGError result;

    /* Fade to black to hide resolution-switching flicker */
    if (CGAcquireDisplayFadeReservation(5, &fade_token) == kCGErrorSuccess) {
        CGDisplayFade(fade_token, 0.3, kCGDisplayBlendNormal, kCGDisplayBlendSolidColor, 0.0, 0.0, 0.0, TRUE);
    }

    if (data == display->desktop_mode.driverdata) {
        /* Restoring desktop mode */
        SetDisplayModeForDisplay(displaydata->display, data);

        if (CGDisplayIsMain(displaydata->display)) {
            CGReleaseAllDisplays();
        } else {
            CGDisplayRelease(displaydata->display);
        }

        if (CGDisplayIsMain(displaydata->display)) {
            Cocoa_ToggleMenuBar(YES);
        }
    } else {
        /* Put up the blanking window (a window above all other windows) */
        if (CGDisplayIsMain(displaydata->display)) {
            /* If we don't capture all displays, Cocoa tries to rearrange windows... *sigh* */
            result = CGCaptureAllDisplays();
        } else {
            result = CGDisplayCapture(displaydata->display);
        }
        if (result != kCGErrorSuccess) {
            CG_SetError("CGDisplayCapture()", result);
            goto ERR_NO_CAPTURE;
        }

        /* Do the physical switch */
        result =  SetDisplayModeForDisplay(displaydata->display, data);
        if (result != kCGErrorSuccess) {
            CG_SetError("CGDisplaySwitchToMode()", result);
            goto ERR_NO_SWITCH;
        }

        /* Hide the menu bar so it doesn't intercept events */
        if (CGDisplayIsMain(displaydata->display)) {
            Cocoa_ToggleMenuBar(NO);
        }
    }

    /* Fade in again (asynchronously) */
    if (fade_token != kCGDisplayFadeReservationInvalidToken) {
        CGDisplayFade(fade_token, 0.5, kCGDisplayBlendSolidColor, kCGDisplayBlendNormal, 0.0, 0.0, 0.0, FALSE);
        CGReleaseDisplayFadeReservation(fade_token);
    }

    return 0;

    /* Since the blanking window covers *all* windows (even force quit) correct recovery is crucial */
ERR_NO_SWITCH:
    if (CGDisplayIsMain(displaydata->display)) {
        CGReleaseAllDisplays();
    } else {
        CGDisplayRelease(displaydata->display);
    }
ERR_NO_CAPTURE:
    if (fade_token != kCGDisplayFadeReservationInvalidToken) {
        CGDisplayFade (fade_token, 0.5, kCGDisplayBlendSolidColor, kCGDisplayBlendNormal, 0.0, 0.0, 0.0, FALSE);
        CGReleaseDisplayFadeReservation(fade_token);
    }
    return -1;
}

void
Cocoa_QuitModes(_THIS)
{
    int i, j;

    for (i = 0; i < _this->num_displays; ++i) {
        SDL_VideoDisplay *display = &_this->displays[i];
        SDL_DisplayModeData *mode;

        if (display->current_mode.driverdata != display->desktop_mode.driverdata) {
            Cocoa_SetDisplayMode(_this, display, &display->desktop_mode);
        }

        mode = (SDL_DisplayModeData *) display->desktop_mode.driverdata;
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1060 && !defined(__ppc__)
        CFRelease(mode->modes);
#else
        Cocoa_ReleaseDisplayMode(_this, mode->moderef);
#endif

        for (j = 0; j < display->num_display_modes; j++) {
            mode = (SDL_DisplayModeData*) display->display_modes[j].driverdata;
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1060 && !defined(__ppc__)
            CFRelease(mode->modes);
#else
            Cocoa_ReleaseDisplayMode(_this, mode->moderef);
#endif
        }
    }
    Cocoa_ToggleMenuBar(YES);
}

#endif /* SDL_VIDEO_DRIVER_COCOA */

/* vi: set ts=4 sw=4 expandtab: */
