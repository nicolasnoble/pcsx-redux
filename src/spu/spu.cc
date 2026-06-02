/***************************************************************************
                            spu.c  -  description
                             -------------------
    begin                : Wed May 15 2002
    copyright            : (C) 2002 by Pete Bernert
    email                : BlackDove@addcom.de
 ***************************************************************************/

/***************************************************************************
 *                                                                         *
 *   This program is free software; you can redistribute it and/or modify  *
 *   it under the terms of the GNU General Public License as published by  *
 *   the Free Software Foundation; either version 2 of the License, or     *
 *   (at your option) any later version. See also the license.txt file for *
 *   additional informations.                                              *
 *                                                                         *
 ***************************************************************************/

//*************************************************************************//
// History of changes:
//
// 2004/09/19 - Pete
// - added option: IRQ handling in the decoded sound buffer areas (Crash Team Racing)
//
// 2004/09/18 - Pete
// - changed global channel var handling to local pointers (hopefully it will help LDChen's port)
//
// 2004/04/22 - Pete
// - finally fixed frequency modulation and made some cleanups
//
// 2003/04/07 - Eric
// - adjusted cubic interpolation algorithm
//
// 2003/03/16 - Eric
// - added cubic interpolation
//
// 2003/03/01 - linuzappz
// - libraryName changes using ALSA
//
// 2003/02/28 - Pete
// - added option for type of interpolation
// - adjusted spu irqs again (Thousant Arms, Valkyrie Profile)
// - added MONO support for MSWindows DirectSound
//
// 2003/02/20 - kode54
// - amended interpolation code, goto GOON could skip initialization of gpos and cause segfault
//
// 2003/02/19 - kode54
// - moved SPU IRQ handler and changed sample flag processing
//
// 2003/02/18 - kode54
// - moved ADSR calculation outside of the sample decode loop, somehow I doubt that
//   ADSR timing is relative to the frequency at which a sample is played... I guess
//   this remains to be seen, and I don't know whether ADSR is applied to noise channels...
//
// 2003/02/09 - kode54
// - one-shot samples now process the end block before stopping
// - in light of removing fmod hack, now processing ADSR on frequency channel as well
//
// 2003/02/08 - kode54
// - replaced easy interpolation with gaussian
// - removed fmod averaging hack
// - changed .sinc to be updated from .iRawPitch, no idea why it wasn't done this way already (<- Pete: because I
// sometimes fail to see the obvious, haharhar :)
//
// 2003/02/08 - linuzappz
// - small bugfix for one usleep that was 1 instead of 1000
// - added settings.get<Mono>() for no stereo (Linux)
//
// 2003/01/22 - Pete
// - added easy interpolation & small noise adjustments
//
// 2003/01/19 - Pete
// - added Neill's reverb
//
// 2003/01/12 - Pete
// - added recording window handlers
//
// 2003/01/06 - Pete
// - added Neill's ADSR timings
//
// 2002/12/28 - Pete
// - adjusted spu irq handling, fmod handling and loop handling
//
// 2002/08/14 - Pete
// - added extra reverb
//
// 2002/06/08 - linuzappz
// - SPUupdate changed for SPUasync
//
// 2002/05/15 - Pete
// - generic cleanup for the Peops release
//
//*************************************************************************//

#include <chrono>
#include <thread>

#include "spu/adsr.h"
#include "spu/externals.h"
#include "spu/interface.h"

////////////////////////////////////////////////////////////////////////
// globals
////////////////////////////////////////////////////////////////////////

////////////////////////////////////////////////////////////////////////
// CODE AREA
////////////////////////////////////////////////////////////////////////

////////////////////////////////////////////////////////////////////////
// START SOUND... called by main thread to setup a new sound on a channel
////////////////////////////////////////////////////////////////////////

inline void PCSX::SPU::impl::StartSound(SPUCHAN *pChannel) {
    auto &SB = pChannel->data.get<PCSX::SPU::Chan::SB>().value;
    pChannel->adsr.keyOn();
    StartREVERB(pChannel);

    pChannel->adpcm.keyOn();  // rewind decode cursor to sample start, clear IIR history

    pChannel->data.get<PCSX::SPU::Chan::SBPos>().value = 28;

    pChannel->data.get<PCSX::SPU::Chan::New>().value = false;  // init channel flags
    pChannel->data.get<PCSX::SPU::Chan::Stop>().value = false;
    pChannel->data.get<PCSX::SPU::Chan::On>().value = true;

    pChannel->interp.keyOn(SB.data(), &pChannel->data.get<PCSX::SPU::Chan::spos>().value,
                           settings.get<Interpolation>());
}

////////////////////////////////////////////////////////////////////////
// ALL KIND OF HELPERS
////////////////////////////////////////////////////////////////////////

inline void PCSX::SPU::impl::VoiceChangeFrequency(SPUCHAN *pChannel) {
    auto &SB = pChannel->data.get<PCSX::SPU::Chan::SB>().value;
    pChannel->data.get<PCSX::SPU::Chan::UsedFreq>().value =
        pChannel->data.get<PCSX::SPU::Chan::ActFreq>().value;  // -> take it and calc steps
    pChannel->data.get<PCSX::SPU::Chan::sinc>().value = pChannel->data.get<PCSX::SPU::Chan::RawPitch>().value << 4;
    if (!pChannel->data.get<PCSX::SPU::Chan::sinc>().value) pChannel->data.get<PCSX::SPU::Chan::sinc>().value = 1;
    // -> freq change in simple interpolation mode: set the recompute flag
    pChannel->interp.onFrequencyChanged(SB.data(), settings.get<Interpolation>());
}

////////////////////////////////////////////////////////////////////////

inline void PCSX::SPU::impl::FModChangeFrequency(SPUCHAN *pChannel, int ns) {
    auto &SB = pChannel->data.get<PCSX::SPU::Chan::SB>().value;
    int NP = pChannel->data.get<PCSX::SPU::Chan::RawPitch>().value;

    NP = ((32768L + iFMod[ns]) * NP) / 32768L;

    if (NP > 0x3fff) NP = 0x3fff;
    if (NP < 0x1) NP = 0x1;

    NP = (44100L * NP) / (4096L);  // calc frequency

    pChannel->data.get<PCSX::SPU::Chan::ActFreq>().value = NP;
    pChannel->data.get<PCSX::SPU::Chan::UsedFreq>().value = NP;
    pChannel->data.get<PCSX::SPU::Chan::sinc>().value = (((NP / 10) << 16) / 4410);
    if (!pChannel->data.get<PCSX::SPU::Chan::sinc>().value) pChannel->data.get<PCSX::SPU::Chan::sinc>().value = 1;
    // freq change in simple interpolation mode: set the recompute flag
    pChannel->interp.onFrequencyChanged(SB.data(), settings.get<Interpolation>());

    iFMod[ns] = 0;
}

////////////////////////////////////////////////////////////////////////
// MAIN SPU FUNCTION
// here is the main job handler... thread, timer or direct func call
// basically the whole sound processing is done in this fat func!
////////////////////////////////////////////////////////////////////////

////////////////////////////////////////////////////////////////////////

void PCSX::SPU::impl::MainThread() {
    int fa, ns;
    uint8_t *start;
    int ch, flags, d;
    int bIRQReturn = 0;
    int32_t tmpCapVoice1Index = 0;
    int32_t tmpCapVoice3Index = 0;

    SPUCHAN *pChannel;
    while (!bEndThread)  // until we are shutting down
    {
        int voldiv = 4 - settings.get<Volume>();
        //--------------------------------------------------//
        // ok, at the beginning we are looking if there is
        // enuff free place in the dsound/oss buffer to
        // fill in new data, or if there is a new channel to start.
        // if not, we wait (thread) or return (timer/spuasync)
        // until enuff free place is available/a new channel gets
        // started

        if (dwNewChannel)    // new channel should start immedately?
        {                    // (at least one bit 0 ... MAXCHANNEL is set?)
            iSecureStart++;  // -> set iSecure
            if (iSecureStart > 5)
                iSecureStart = 0;  //    (if it is set 5 times - that means on 5 tries a new samples has been started -
                                   //    in a row, we will reset it, to give the sound update a chance)
        } else
            iSecureStart = 0;  // 0: no new channel should start

        while (!iSecureStart && !bEndThread &&              // no new start? no thread end?
               (m_audioOut.getBytesBuffered() > TESTSIZE))  // and still enuff data in sound buffer?
        {
            iSecureStart = 0;  // reset secure

            using namespace std::chrono_literals;
            std::this_thread::sleep_for(5ms);

            if (dwNewChannel)
                iSecureStart =
                    1;  // if a new channel kicks in (or, of course, sound buffer runs low), we will leave the loop
        }

        //--------------------------------------------------// continue from irq handling in timer mode?

        if (lastch >= 0)  // will be -1 if no continue is pending
        {
            ch = lastch;
            ns = lastns;
            lastch = -1;  // -> setup all kind of vars to continue
            pChannel = &s_chan[ch];
            goto GOON;  // -> directly jump to the continue point
        }

        tmpCapVoice1Index = capBufVoiceIndex;
        tmpCapVoice3Index = capBufVoiceIndex;

        //--------------------------------------------------//
        //- main channel loop                              -//
        //--------------------------------------------------//
        {
            pChannel = s_chan;
            for (ch = 0; ch < MAXCHAN;
                 ch++, pChannel++)  // loop em all... we will collect 1 ms of sound of each playing channel
            {
                if (pChannel->data.get<PCSX::SPU::Chan::New>().value) {
                    StartSound(pChannel);        // start new sound
                    dwNewChannel &= ~(1 << ch);  // clear new channel bit
                }

                if (!pChannel->data.get<PCSX::SPU::Chan::On>().value) {
                    // Although the voices may stop outputting audio, the capture buffer is still filling up.
                    if (pMixIrq && ch == 1) {
                        std::unique_lock<std::mutex> lock(cbMtx);
                        for (int c = 0; c < NSSIZE; c++) spuMem[tmpCapVoice1Index + c + 0x400] = 0;
                        tmpCapVoice1Index = (tmpCapVoice1Index + NSSIZE) % 0x200;
                    } else if (pMixIrq && ch == 3) {
                        std::unique_lock<std::mutex> lock(cbMtx);
                        for (int c = 0; c < NSSIZE; c++) spuMem[tmpCapVoice3Index + c + 0x600] = 0;
                        tmpCapVoice3Index = (tmpCapVoice3Index + NSSIZE) % 0x200;
                    }
                    continue;  // channel not playing? next
                }

                if (pChannel->data.get<PCSX::SPU::Chan::ActFreq>().value !=
                    pChannel->data.get<PCSX::SPU::Chan::UsedFreq>().value)  // new psx frequency?
                    VoiceChangeFrequency(pChannel);

                ns = 0;

                while (ns < NSSIZE)  // loop until 1 ms of data is reached
                {
                    m_noise.step();

                    if (pChannel->data.get<PCSX::SPU::Chan::FMod>().value == 1 && iFMod[ns])  // fmod freq channel
                        FModChangeFrequency(pChannel, ns);

                    while (pChannel->data.get<PCSX::SPU::Chan::spos>().value >= 0x10000L) {
                        if (pChannel->data.get<PCSX::SPU::Chan::SBPos>().value == 28)  // 28 reached?
                        {
                            start = pChannel->adpcm.curr();  // set up the current pos

                            if (start == (uint8_t *)-1)  // special "stop" sign
                            {
                                pChannel->data.get<PCSX::SPU::Chan::On>().value = false;  // -> turn everything off
                                pChannel->adsr.ex().get<exVolume>().value = 0;
                                pChannel->adsr.ex().get<exEnvelopeVol>().value = 0;
                                // Although the voices may stop outputting audio, the capture buffer is still filling
                                // up. At this point, ns samples are already filled, we need (NSSIZE-ns) more samples.
                                if (pMixIrq && ch == 1) {
                                    std::unique_lock<std::mutex> lock(cbMtx);
                                    for (int c = ns; c < NSSIZE; c++) spuMem[tmpCapVoice1Index + c + 0x400] = 0;
                                    tmpCapVoice1Index = (tmpCapVoice1Index + (NSSIZE - ns)) % 0x200;
                                } else if (pMixIrq && ch == 3) {
                                    std::unique_lock<std::mutex> lock(cbMtx);
                                    for (int c = ns; c < NSSIZE; c++) spuMem[tmpCapVoice3Index + c + 0x600] = 0;
                                    tmpCapVoice3Index = (tmpCapVoice3Index + (NSSIZE - ns)) % 0x200;
                                }
                                goto ENDX;  // -> and done for this channel
                            }

                            pChannel->data.get<PCSX::SPU::Chan::SBPos>().value = 0;

                            //////////////////////////////////////////// spu irq handler here? mmm... do it later

                            // Decode the 16-byte ADPCM block at the cursor into the 28-sample buffer.
                            // The decoder owns the predictor/shift parse and the s_1/s_2 IIR history;
                            // it advances start to one past the block and hands back the flag byte.
                            flags = pChannel->adpcm.decodeBlock(
                                start, pChannel->data.get<PCSX::SPU::Chan::SB>().value.data(), start);

                            //////////////////////////////////////////// irq check

                            if ((spuCtrl & ControlFlags::IRQEnable))  // some callback and irq active?
                            {
                                if ((pSpuIrq > start - 16 &&  // irq address reached?
                                     pSpuIrq <= start) ||
                                    ((flags & 1) &&  // special: irq on looping addr, when stop/loop flag is set
                                     (pSpuIrq > pChannel->adpcm.loop() - 16 && pSpuIrq <= pChannel->adpcm.loop()))) {
                                    pChannel->data.get<PCSX::SPU::Chan::IrqDone>().value = 1;  // -> debug flag
                                    scheduleInterrupt();                                       // -> call main emu

                                    if (settings.get<SPUIRQWait>())  // -> option: wait after irq for main emu
                                    {
                                        iSpuAsyncWait = 1;
                                        bIRQReturn = 1;
                                    }
                                }
                            }

                            //////////////////////////////////////////// flag handler

                            if ((flags & 4) && (!pChannel->data.get<PCSX::SPU::Chan::IgnoreLoop>().value))
                                pChannel->adpcm.setLoop(start - 16);  // loop adress

                            if (flags & 1)  // 1: stop/loop
                            {
                                // We play this block out first...
                                // if(!(flags&2))                          // 1+2: do loop... otherwise: stop
                                if (flags != 3 ||
                                    pChannel->adpcm.loop() == NULL)  // PETE: if we don't check exactly for 3, loop hang
                                                                     // ups will happen (DQ4, for example)
                                {  // and checking if pLoop is set avoids crashes, yeah
                                    start = (uint8_t *)-1;
                                } else {
                                    start = pChannel->adpcm.loop();
                                }
                            }

                            pChannel->adpcm.setCurr(start);  // store cursor for next cycle

                            ////////////////////////////////////////////

                            if (bIRQReturn)  // special return for "spu irq - wait for cpu action"
                            {
                                using namespace std::chrono_literals;
                                bIRQReturn = 0;
                                auto dwWatchTime = std::chrono::steady_clock::now() + 2500ms;

                                while (iSpuAsyncWait && !bEndThread && std::chrono::steady_clock::now() < dwWatchTime) {
                                    std::this_thread::sleep_for(1ms);
                                }
                            }

                            ////////////////////////////////////////////

                        GOON:;
                        }

                        fa = pChannel->data.get<PCSX::SPU::Chan::SB>()
                                 .value[pChannel->data.get<PCSX::SPU::Chan::SBPos>().value++]
                                 .value;  // get sample data

                        pChannel->interp.storeVal(pChannel->data.get<PCSX::SPU::Chan::SB>().value.data(), fa,
                                                  settings.get<Interpolation>(),
                                                  pChannel->data.get<PCSX::SPU::Chan::FMod>().value,
                                                  (spuCtrl & ControlFlags::Mute) != 0);  // store val for interpolation

                        pChannel->data.get<PCSX::SPU::Chan::spos>().value -= 0x10000L;
                    }

                    ////////////////////////////////////////////////

                    if (pChannel->data.get<PCSX::SPU::Chan::Noise>().value)
                        fa = m_noise.getVal(pChannel->data.get<PCSX::SPU::Chan::SB>().value.data(),
                                            settings.get<Interpolation>());  // get noise val
                    else
                        fa = pChannel->interp.getVal(pChannel->data.get<PCSX::SPU::Chan::SB>().value.data(),
                                                     pChannel->data.get<PCSX::SPU::Chan::spos>().value,
                                                     pChannel->data.get<PCSX::SPU::Chan::sinc>().value,
                                                     settings.get<Interpolation>(),
                                                     pChannel->data.get<PCSX::SPU::Chan::FMod>().value);  // get sample

                    int32_t mixedSample = (pChannel->adsr.step(pChannel->data.get<PCSX::SPU::Chan::Stop>().value,
                                                               pChannel->data.get<PCSX::SPU::Chan::On>().value) *
                                           fa) /
                                          1023;  // mix adsr
                    pChannel->data.get<PCSX::SPU::Chan::sval>().value = mixedSample;

                    // Capture buffer should contain voice1/3 sample after any adsr processing but before volume
                    // processing?
                    mixedSample = std::min(0xFFFF, std::max(-0xFFFF, mixedSample));
                    if (pMixIrq && ch == 1) {
                        std::unique_lock<std::mutex> lock(cbMtx);
                        spuMem[tmpCapVoice1Index + 0x400] = mixedSample;
                        tmpCapVoice1Index = (tmpCapVoice1Index + 1) % 0x200;
                    } else if (pMixIrq && ch == 3) {
                        std::unique_lock<std::mutex> lock(cbMtx);
                        spuMem[tmpCapVoice3Index + 0x600] = mixedSample;
                        tmpCapVoice3Index = (tmpCapVoice3Index + 1) % 0x200;
                    }

                    if (pChannel->data.get<PCSX::SPU::Chan::FMod>().value == 2)  // fmod freq channel
                        iFMod[ns] = pChannel->data.get<PCSX::SPU::Chan::sval>()
                                        .value;  // -> store 1T sample data, use that to do fmod on next channel
                    else                         // no fmod freq channel
                    {
                        //////////////////////////////////////////////
                        // ok, left/right sound volume (psx volume goes from 0 ... 0x3fff)

                        if (pChannel->data.get<PCSX::SPU::Chan::Mute>().value &&
                            !pChannel->data.get<PCSX::SPU::Chan::Solo>().value)
                            pChannel->data.get<PCSX::SPU::Chan::sval>().value = 0;  // debug mute
                        else {
                            SSumL[ns] +=
                                (pChannel->data.get<PCSX::SPU::Chan::sval>().value * pChannel->volume.left()) / 0x4000L;
                            SSumR[ns] +=
                                (pChannel->data.get<PCSX::SPU::Chan::sval>().value * pChannel->volume.right()) / 0x4000L;
                        }

                        //////////////////////////////////////////////
                        // now let us store sound data for reverb

                        if (pChannel->data.get<PCSX::SPU::Chan::RVBActive>().value) StoreREVERB(pChannel, ns);
                    }

                    ////////////////////////////////////////////////
                    // ok, go on until 1 ms data of this channel is collected

                    ns++;
                    pChannel->data.get<PCSX::SPU::Chan::spos>().value +=
                        pChannel->data.get<PCSX::SPU::Chan::sinc>().value;
                }
            ENDX:;
            }
        }

        // Write from our temporary capture buffer to the actual SPU RAM.
        writeCaptureBufferCD(NSSIZE);

        // Advance the persistent capture write pointer by one batch and reflect
        // which half of the 0x200-sample capture buffer it now points at in
        // SPUSTAT bit 11 (0=first half 0x000-0x0ff, 1=second half 0x100-0x1ff).
        // Hardware toggles this bit as the 44.1kHz capture pointer crosses the
        // half boundary; guests sync capture reads on its edge.
        capBufVoiceIndex = (capBufVoiceIndex + NSSIZE) % 0x200;
        if (capBufVoiceIndex & 0x100)
            spuStat |= StatusFlags::CBIndex;
        else
            spuStat &= ~StatusFlags::CBIndex;

        //---------------------------------------------------//
        //- here we have another 1 ms of sound data
        //---------------------------------------------------//

        ///////////////////////////////////////////////////////
        // mix all channels (including reverb) into one buffer

        for (ns = 0; ns < NSSIZE; ns++) {
            SSumL[ns] += MixREVERBLeft(ns);

            d = SSumL[ns] / voldiv;
            SSumL[ns] = 0;
            if (d < -32767) d = -32767;
            if (d > 32767) d = 32767;
            *pS++ = d;

            SSumR[ns] += MixREVERBRight();

            d = SSumR[ns] / voldiv;
            SSumR[ns] = 0;
            if (d < -32767) d = -32767;
            if (d > 32767) d = 32767;
            *pS++ = d;
        }

        //////////////////////////////////////////////////////
        // special irq handling in the decode buffers (0x0000-0x1000)
        // we know:
        // the decode buffers are located in spu memory in the following way:
        // 0x0000-0x03ff  CD audio left
        // 0x0400-0x07ff  CD audio right
        // 0x0800-0x0bff  Voice 1
        // 0x0c00-0x0fff  Voice 3
        // and decoded data is 16 bit for one sample
        // we assume:
        // even if voices 1/3 are off or no cd audio is playing, the internal
        // play positions will move on and wrap after 0x400 bytes.
        // Therefore: we just need a pointer from spumem+0 to spumem+3ff, and
        // increase this pointer on each sample by 2 bytes. If this pointer
        // (or 0x400 offsets of this pointer) hits the spuirq address, we generate
        // an IRQ. Only problem: the "wait for cpu" option is kinda hard to do here
        // in some of Peops timer modes. So: we ignore this option here (for now).
        // Also note: we abuse the channel 0-3 irq debug display for those irqs
        // (since that's the easiest way to display such irqs in debug mode :))

        if (pMixIrq)  // pMixIRQ will only be set, if the config option is active
        {
            for (ns = 0; ns < NSSIZE; ns++) {
                if ((spuCtrl & ControlFlags::IRQEnable) && pSpuIrq && pSpuIrq < spuMemC + 0x1000) {
                    for (ch = 0; ch < 4; ch++) {
                        if (pSpuIrq >= pMixIrq + (ch * 0x400) && pSpuIrq < pMixIrq + (ch * 0x400) + 2) {
                            scheduleInterrupt();
                            s_chan[ch].data.get<PCSX::SPU::Chan::IrqDone>().value = 1;
                        }
                    }
                }
                pMixIrq += 2;
                if (pMixIrq > spuMemC + 0x3ff) pMixIrq = spuMemC;
            }
        }

        InitREVERB();

        //////////////////////////////////////////////////////
        // feed the sound
        // wanna have around 1/60 sec (16.666 ms) updates

        if (iCycle++ > 16) {
            bool done = false;
            while (!done) {
                done =
                    m_audioOut.feedStreamData(reinterpret_cast<MiniAudio::Frame *>(pSpuBuffer),
                                              (((uint8_t *)pS) - ((uint8_t *)pSpuBuffer)) / sizeof(MiniAudio::Frame));
                if (bEndThread) {
                    bThreadEnded = 1;
                    return;
                }
            }
            pS = (int16_t *)pSpuBuffer;
            iCycle = 0;
        }
    }

    // end of big main loop...

    bThreadEnded = 1;
}

void PCSX::SPU::impl::writeCaptureBufferCD(int numbSamples) {
    if (pMixIrq) {
        std::unique_lock<std::mutex> lock(cbMtx);
        for (int n = 0; n < numbSamples; n++) {
            if (captureBuffer.startIndex == captureBuffer.endIndex) {
                // If there are no samples left in the temp buffer,
                // we still HAVE to keep writing to the capture buffer.
                spuMem[captureBuffer.currIndex] = 0;
                spuMem[captureBuffer.currIndex + 0x200] = 0;
            } else {
                spuMem[captureBuffer.currIndex] = captureBuffer.CDCapLeft[captureBuffer.startIndex];
                spuMem[captureBuffer.currIndex + 0x200] = captureBuffer.CDCapRight[captureBuffer.startIndex];
                captureBuffer.startIndex = (captureBuffer.startIndex + 1) % CaptureBuffer::CB_SIZE;
            }
            captureBuffer.currIndex = (captureBuffer.currIndex + 1) % 0x200;
        }
        // Update the capture buffer voice index, which in the end, should be the same as
        // tmpCapVoice1Index, tmpCapVoice3Index and captureBuffer.currIndex.
        // Unless I'm missing something in Pete's code.
        /* capBufVoiceIndex = (capBufVoiceIndex + NSSIZE) % 0x200;
        if ((tmpCapVoice1Index != tmpCapVoice3Index) || (tmpCapVoice3Index != captureBuffer.currIndex) ||
            (captureBuffer.currIndex != capBufVoiceIndex))
            g_system->log(LogClass::SPU, "Capture buffer indices are not the same.\n");*/
    }
}

////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////

////////////////////////////////////////////////////////////////////////
// SPU ASYNC... even newer epsxe func
//  1 time every 'cycle' cycles... harhar
////////////////////////////////////////////////////////////////////////

void PCSX::SPU::impl::async(uint32_t cycle) {
    if (iSpuAsyncWait) {
        iSpuAsyncWait++;
        if (iSpuAsyncWait <= 64) return;
        iSpuAsyncWait = 0;
    }
}

////////////////////////////////////////////////////////////////////////
// XA AUDIO
////////////////////////////////////////////////////////////////////////

void PCSX::SPU::impl::playADPCMchannel(xa_decode_t *xap) {
    if (!settings.get<Streaming>()) return;  // no XA? bye
    if (!xap) return;
    if (!xap->freq) return;  // no xa freq ? bye

    FeedXA(xap);  // call main XA feeder
}

////////////////////////////////////////////////////////////////////////
// INIT/EXIT STUFF
////////////////////////////////////////////////////////////////////////

////////////////////////////////////////////////////////////////////////
// SPUINIT: this func will be called first by the main emu
////////////////////////////////////////////////////////////////////////

long PCSX::SPU::impl::init(void) {
    spuMemC = (uint8_t *)spuMem;  // just small setup

    wipeChannels();
    return 0;
}

void PCSX::SPU::impl::wipeChannels() {
    for (unsigned i = 0; i < MAXCHAN; i++) {
        s_chan[i].adsr.reset();
        s_chan[i].adpcm.reset();
        s_chan[i].volume.reset();
        s_chan[i].data.reset();
    }
    memset((void *)&rvb, 0, sizeof(REVERBInfo));
}

////////////////////////////////////////////////////////////////////////
// SETUPTIMER: init of certain buffers and threads/timers
////////////////////////////////////////////////////////////////////////

void PCSX::SPU::impl::SetupThread() {
    memset(SSumR, 0, NSSIZE * sizeof(int));  // init some mixing buffers
    memset(SSumL, 0, NSSIZE * sizeof(int));
    memset(iFMod, 0, NSSIZE * sizeof(int));

    pS = (int16_t *)pSpuBuffer;  // setup soundbuffer pointer

    bEndThread = 0;  // init thread vars
    bThreadEnded = 0;
    bSpuInit = 1;  // flag: we are inited

    hMainThread = std::thread([this]() { MainThread(); });
}

////////////////////////////////////////////////////////////////////////
// REMOVETIMER: kill threads/timers
////////////////////////////////////////////////////////////////////////

void PCSX::SPU::impl::RemoveThread() {
    bEndThread = 1;  // raise flag to end thread

    using namespace std::chrono_literals;
    while (!bThreadEnded) {
        std::this_thread::sleep_for(5ms);
    }  // -> wait till thread has ended
    std::this_thread::sleep_for(5ms);

    hMainThread.join();

    bThreadEnded = 0;  // no more spu is running
    bSpuInit = 0;
}

////////////////////////////////////////////////////////////////////////
// SETUPSTREAMS: init most of the spu buffers
////////////////////////////////////////////////////////////////////////

void PCSX::SPU::impl::SetupStreams() {
    int i;

    pSpuBuffer = (uint8_t *)malloc(32768);  // alloc mixing buffer

    if (settings.get<Reverb>() == 1)
        i = 88200 * 2;
    else
        i = NSSIZE * 2;

    sRVBStart = (int *)malloc(i * 4);  // alloc reverb buffer
    memset(sRVBStart, 0, i * 4);
    sRVBEnd = sRVBStart + i;
    sRVBPlay = sRVBStart;

    for (i = 0; i < MAXCHAN; i++)  // loop sound channels
    {
        // we don't use mutex sync... not needed, would only
        // slow us down:
        //   s_chan[i].hMutex=CreateMutex(NULL,FALSE,NULL);
        s_chan[i].adsr.ex().get<exSustainLevel>().value = 0xf << 27;  // -> init sustain
        s_chan[i].data.get<PCSX::SPU::Chan::Mute>().value = false;
        s_chan[i].data.get<PCSX::SPU::Chan::Solo>().value = false;
        s_chan[i].data.get<PCSX::SPU::Chan::IrqDone>().value = 0;
        s_chan[i].adpcm.setLoop(spuMemC);
        s_chan[i].adpcm.setStart(spuMemC);
        s_chan[i].adpcm.setCurr(spuMemC);
    }
}

////////////////////////////////////////////////////////////////////////
// REMOVESTREAMS: free most buffer
////////////////////////////////////////////////////////////////////////

void PCSX::SPU::impl::RemoveStreams(void) {
    free(pSpuBuffer);  // free mixing buffer
    pSpuBuffer = NULL;
    free(sRVBStart);  // free reverb buffer
    sRVBStart = 0;
}

////////////////////////////////////////////////////////////////////////
// SPUOPEN: called by main emu after init
////////////////////////////////////////////////////////////////////////

bool PCSX::SPU::impl::open() {
    if (bSPUIsOpen) return true;  // security for some stupid main emus

    iReverbOff = -1;
    spuIrq = 0;
    spuAddr = 0xffffffff;
    bEndThread = 0;
    bThreadEnded = 0;
    spuMemC = (uint8_t *)spuMem;
    pMixIrq = 0;
    wipeChannels();
    pSpuIrq = 0;

    //    ReadConfig();  // read user stuff

    SetupStreams();  // prepare streaming

    SetupThread();  // timer for feeding data

    bSPUIsOpen = 1;

    m_lastUpdated = std::chrono::steady_clock::now();

    resetCaptureBuffer();

    return true;
}

////////////////////////////////////////////////////////////////////////
// SPUCLOSE: called before shutdown
////////////////////////////////////////////////////////////////////////

long PCSX::SPU::impl::close(void) {
    if (!bSPUIsOpen) return 0;  // some security

    bSPUIsOpen = 0;  // no more open

    RemoveThread();   // no more feeding
    RemoveStreams();  // no more streaming

    return 0;
}

////////////////////////////////////////////////////////////////////////
// SPUSHUTDOWN: called by main emu on final exit
////////////////////////////////////////////////////////////////////////

long PCSX::SPU::impl::shutdown(void) { return 0; }

////////////////////////////////////////////////////////////////////////
// SETUP CALLBACKS
// this functions will be called once,
// passes a callback that should be called on SPU-IRQ/cdda volume change
////////////////////////////////////////////////////////////////////////

void PCSX::SPU::impl::registerCDDAVolume(void (*CDDAVcallback)(uint16_t, uint16_t)) { cddavCallback = CDDAVcallback; }

////////////////////////////////////////////////////////////////////////

void PCSX::SPU::impl::playCDDAchannel(int16_t *data, int size) {
    m_cdda.freq = 44100;
    m_cdda.nsamples = size / 4;
    m_cdda.stereo = 1;
    m_cdda.nbits = 16;
    memcpy(m_cdda.pcm, data, size);
    FeedXA(&m_cdda);
}

void PCSX::SPU::impl::setLua(Lua L) {
    L.getfieldtable("PCSX", LUA_GLOBALSINDEX);
    L.getfieldtable("settings");
    L.push("spu");
    settings.pushValue(L);
    L.settable();
    L.pop();
    L.pop();
}
