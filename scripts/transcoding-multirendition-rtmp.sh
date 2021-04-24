#!/usr/bin/env bash

if [ $# -lt 1 ]; then
	echo "Use ./transcoding-multirendition-rtmp.sh test/live [RTMPPort] [RTMPApp] [RTMPStream] [HLSOutHostPort]"
    echo "test/live: Generates test signal, no need for RTMP source"
    echo "RTMPPort: RTMP local port (default: 1935)"
    echo "RTMPPort: RTMP app name (default: \"live\")"
    echo "RTMPPort: RTMP stream name (default: \"stream\")"
    echo "HLSOutHostPort: Host and to send HLS data (default: \"localhost:9094\")"
    echo "Example: ./transcoding-multirendition-rtmp.sh live \"localhost:9094\" 1935 \"live\" \"stream\""
    exit 1
fi

MODE="${1}"
RTMP_PORT="${2:-"1935"}"
RTMP_APP="${3:-"live"}"
RTMP_STREAM="${4:-"stream"}"
HOST_DST="${5:-"localhost:9094"}"

PATH_NAME="mrrtmp"
STREAM_NAME_720p="720p"
STREAM_NAME_480p="480p"
BASE_DIR="../results/${PATH_NAME}"
LOGS_DIR="../logs"
GO_BINARY_DIR="~/go/bin"
eval TS_SEGMENTER_BIN="$GO_BINARY_DIR/go-ts-segmenter"

# Check segmenter binary
if [ ! -f $TS_SEGMENTER_BIN ]; then
    echo "$TS_SEGMENTER_BIN does not exist."
    exit 1
fi

# Clean up
echo "Restarting ${BASE_DIR} directory"
rm -rf $BASE_DIR/*
mkdir -p $BASE_DIR
mkdir -p $LOGS_DIR

# Create master playlist (this should be created after 1st chunk is uploaded)
# Assuming source is 1280x720@6Mbps (or better)
# Creating 720p@6Mbps and 480p@3Mbps
echo "Creating master playlist manifest (playlist.m3u8)"
echo "#EXTM3U" > $BASE_DIR/playlist.m3u8
echo "#EXT-X-VERSION:3" >> $BASE_DIR/playlist.m3u8
echo "#EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1280x720" >> $BASE_DIR/playlist.m3u8
echo "$STREAM_NAME_720p.m3u8" >> $BASE_DIR/playlist.m3u8
echo "#EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=854x480" >> $BASE_DIR/playlist.m3u8
echo "$STREAM_NAME_480p.m3u8" >> $BASE_DIR/playlist.m3u8

# Upload master playlist
curl "http://${HOST_DST}/${PATH_NAME}/playlist.m3u8" -H "Content-Type: application/vnd.apple.mpegurl" --upload-file $BASE_DIR/playlist.m3u8

# Select font path based in OS
if [[ "$OSTYPE" == "linux-gnu" ]]; then
    FONT_PATH='/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf'
elif [[ "$OSTYPE" == "darwin"* ]]; then
    FONT_PATH='/Library/Fonts/Arial.ttf'
fi

# Creates pipes
FIFO_FILENAME_720p="fifo-$STREAM_NAME_720p"
mkfifo $BASE_DIR/$FIFO_FILENAME_720p
FIFO_FILENAME_480p="fifo-$STREAM_NAME_480p"
mkfifo $BASE_DIR/$FIFO_FILENAME_480p

# Creates hls producers
cat "$BASE_DIR/$FIFO_FILENAME_720p" | $TS_SEGMENTER_BIN -logsPath "$LOGS_DIR/segmenter720p.log" -dstPath ${PATH_NAME} -manifestDestinationType 2 -mediaDestinationType 2 -targetDur 1 -lhls 3 -chunksBaseFilename ${STREAM_NAME_720p}_ -chunklistFilename ${STREAM_NAME_720p}.m3u8 &
PID_720p=$!
echo "Started go-ts-segmenter for $STREAM_NAME_720p as PID $PID_720p"
cat "$BASE_DIR/$FIFO_FILENAME_480p" | $TS_SEGMENTER_BIN -logsPath "$LOGS_DIR/segmenter480p.log" -dstPath ${PATH_NAME} -manifestDestinationType 2 -mediaDestinationType 2 -targetDur 1 -lhls 3 -chunksBaseFilename ${STREAM_NAME_480p}_ -chunklistFilename ${STREAM_NAME_480p}.m3u8 &
PID_480p=$!
echo "Started go-ts-segmenter for $STREAM_NAME_480p as PID $PID_480p"

if [[ "$MODE" == "test" ]]; then
    # Start test signal
    # GOP size = 30f @ 30 fps = 1s
    ffmpeg -hide_banner -y \
    -f lavfi -re -i smptebars=duration=36000:size=1280x720:rate=30 \
    -f lavfi -i sine=frequency=1000:duration=36000:sample_rate=48000 -pix_fmt yuv420p \
    -s 1280x720 -vf "drawtext=fontfile=$FONT_PATH:text=\'RENDITION 720p - Local time %{localtime\: %Y\/%m\/%d %H.%M.%S} (%{n})\':x=10:y=350:fontsize=30:fontcolor=pink:box=1:boxcolor=0x00000099" \
    -c:v libx264 -tune zerolatency -b:v 6000k -g 30 -preset ultrafast \
    -c:a aac -b:a 48k \
    -f mpegts "$BASE_DIR/$FIFO_FILENAME_720p" \
    -s 854x480 -vf "drawtext=fontfile=$FONT_PATH:text=\'RENDITION 480p - Local time %{localtime\: %Y\/%m\/%d %H.%M.%S} (%{n})\':x=10:y=350:fontsize=30:fontcolor=pink:box=1:boxcolor=0x00000099" \
    -c:v libx264 -tune zerolatency -b:v 3000k -g 30 -preset ultrafast \
    -c:a aac -b:a 48k \
    -f mpegts "$BASE_DIR/$FIFO_FILENAME_480p"
else
    # Start transmuxer
    ffmpeg -hide_banner -y \
    -listen 1 -i "rtmp://0.0.0.0:$RTMP_PORT/$RTMP_APP/$RTMP_STREAM" \
    -s 1280x720 -vf "drawtext=fontfile=$FONT_PATH:text=\'RENDITION 720p - Local time %{localtime\: %Y\/%m\/%d %H.%M.%S} (%{n})\':x=10:y=350:fontsize=30:fontcolor=pink:box=1:boxcolor=0x00000099" \
    -c:v libx264 -tune zerolatency -b:v 6000k -g 30 -preset ultrafast \
    -c:a aac -b:a 48k \
    -f mpegts "$BASE_DIR/$FIFO_FILENAME_720p" \
    -s 854x480 -vf "drawtext=fontfile=$FONT_PATH:text=\'RENDITION 480p - Local time %{localtime\: %Y\/%m\/%d %H.%M.%S} (%{n})\':x=10:y=350:fontsize=30:fontcolor=pink:box=1:boxcolor=0x00000099" \
    -c:v libx264 -tune zerolatency -b:v 3000k -g 30 -preset ultrafast \
    -c:a aac -b:a 48k \
    -f mpegts "$BASE_DIR/$FIFO_FILENAME_480p"
fi

# Clean up: Stop processes
# If the input stream stops the segmenter processes exists themselves
# kill $PID_720p
# kill $PID_480p
