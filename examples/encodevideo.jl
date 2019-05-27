# Based on https://www.ffmpeg.org/doxygen/trunk/encode_video_8c-example.html
#=
 * Copyright (c) 2001 Fabrice Bellard
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */
=#

using VideoIO, Printf

"""
encode(enc_ctx::Ptr{VideoIO.AVCodecContext}, frame, pktptr::Ptr{VideoIO.AVPacket}, io::IO)

Append and encode frame to output.
"""
function encode(enc_ctx::Ptr{VideoIO.AVCodecContext},
    frame, pktptr::Ptr{VideoIO.AVPacket}, io::IO)
    ret = VideoIO.avcodec_send_frame(enc_ctx, frame)
    if ret < 0
        error("Error $ret sending a frame for encoding")
    end

    while ret >= 0
        ret = VideoIO.avcodec_receive_packet(enc_ctx, pktptr)
        if (ret == -35 || ret == -541478725) # -35=EAGAIN -541478725=AVERROR_EOF
             return
        elseif (ret < 0)
            error("Error $ret during encoding")
        end
        pkt = unsafe_load(pktptr)
        println("Write packet $(pkt.pts) (size=$(pkt.size))")
        data = unsafe_wrap(Array,pkt.data,pkt.size)
        write(io,data)
        VideoIO.av_packet_unref(pktptr)
    end
end

filename = "video"
codec_name = "libx264"
framerate = 24

endcode = UInt8[0, 0, 1, 0xb7]

codec = VideoIO.avcodec_find_encoder_by_name(codec_name)
if codec == C_NULL
    error("Codec '$codec_name' not found")
end

c = Ptr{VideoIO.AVCodecContext}[VideoIO.avcodec_alloc_context3(codec)]
if c == [C_NULL]
    error("Could not allocate video codec context")
end

pktptr = Ptr{VideoIO.AVPacket}[VideoIO.av_packet_alloc()]
if pktptr == [C_NULL]
    error("av_packet_alloc() error")
end

codecContext = unsafe_load(c[1])

#resolution must be a multiple of two
codecContext.width = 352
codecContext.height = 288
# frames per second
codecContext.time_base = VideoIO.AVRational(1, framerate)
codecContext.framerate = VideoIO.AVRational(framerate, 1)
codecContext.pix_fmt = VideoIO.AV_PIX_FMT_YUV420P

unsafe_store!(c[1], codecContext)

codec_loaded = unsafe_load(codec)
if codec_loaded.id == VideoIO.AV_CODEC_ID_H264
    VideoIO.av_opt_set(codecContext.priv_data, "crf", "0", VideoIO.AV_OPT_SEARCH_CHILDREN)
    VideoIO.av_opt_set(codecContext.priv_data, "preset", "veryslow", VideoIO.AV_OPT_SEARCH_CHILDREN)
else
    ## PARAMETERS FROM ORIGINAL EXAMPLE
    # put sample parameters
    codecContext.bit_rate = 400000
    #= emit one intra frame every ten frames
     * check frame pict_type before passing frame
     * to encoder, if frame->pict_type is AV_PICTURE_TYPE_I
     * then gop_size is ignored and the output of encoder
     * will always be I frame irrespective to gop_size
    =#
    codecContext.gop_size = 10        #####
    codecContext.max_b_frames = 1
end

# open it
ret = VideoIO.avcodec_open2(c[1], codec, C_NULL)
if ret < 0
    error("Could not open codec: $(av_err2str(ret))")
end
f = open(string(filename,".h264"),"w")
frameptr = Ptr{VideoIO.AVFrame}[VideoIO.av_frame_alloc()]
if frameptr == [C_NULL]
    error("Could not allocate video frame")
end
frame = unsafe_load(frameptr[1])
frame.format = codecContext.pix_fmt
frame.width  = codecContext.width
frame.height = codecContext.height
unsafe_store!(frameptr[1],frame)

ret = VideoIO.av_frame_get_buffer(frameptr[1], 32)
if ret < 0
    error("Could not allocate the video frame data")
end

# frame_fields = map(x->fieldname(VideoIO.AVUtil.AVFrame,x),1:fieldcount(VideoIO.AVUtil.AVFrame))
# pos_data = findfirst(fields.==:data)

for i = 0:240
    flush(stdout)

    ret = VideoIO.av_frame_make_writable(frameptr[1])
    if ret < 0
        error("av_frame_make_writable() error")
    end

    frame = unsafe_load(frameptr[1]) #grab data from c memory
    Y = rand(UInt8,frame.width,frame.height)
    Cb = rand(UInt8,Int64(frame.width/2),Int64(frame.height/2))
    Cr = rand(UInt8,Int64(frame.width/2),Int64(frame.height/2))
    for y = 1:frame.height
        for x = 1:frame.width
            unsafe_store!(frame.data[1],rand(UInt8),((y-1)*frame.linesize[1])+x)
        end
    end
    for y = 1:Int64(frame.height/2)
        for x = 1:Int64(frame.width/2)
            unsafe_store!(frame.data[2],Cb[x,y],((y-1)*frame.linesize[2])+x)
            unsafe_store!(frame.data[3],Cr[x,y],((y-1)*frame.linesize[3])+x)
        end
    end

    frame.pts = i
    unsafe_store!(frameptr[1],frame) #pass data back to c memory

    encode(c[1], frameptr[1], pktptr[1], f)
    println(i)
end

# flush the encoder
encode(c[1], C_NULL, pktptr[1], f);
# add sequence end code to have a real MPEG file
write(f,endcode)
close(f)

VideoIO.avcodec_free_context(c)
VideoIO.av_frame_free(frameptr)
VideoIO.av_packet_free(pktptr)

overwrite = true
ow = overwrite ? `-y` : `-n`

muxout = VideoIO.collectexecoutput(`$(VideoIO.ffmpeg) $ow -framerate $framerate -i $filename.h264 -c copy $filename.mp4`)

filter!(x->!occursin.("Timestamps are unset in a packet for stream 0.",x),muxout)
if occursin("ffmpeg version ",muxout[1]) && occursin("video:",muxout[end])
    rm("$filename.h264")
    @info "Video file saved: $(pwd())/$filename.mp4"
    @info muxout[end-1]
    @info muxout[end]
    return
else
    rm("$filename.h264")
    @warn "Stream Muxing may have failed: $(pwd())/$filename.h264 into $(pwd())/$filename.mp4"
    println.(muxout)
end
