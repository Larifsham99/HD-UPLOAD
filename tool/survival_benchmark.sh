#!/usr/bin/env bash
# Measures whether TikTok Survival Mode pre-conditioning helps a video survive
# a TikTok-like re-encode (H.264 ~2.5 Mbps 1080p). Prints SSIM/PSNR against the
# clean scene. Synthetic content + simulated sensor noise; real footage varies.
set -euo pipefail
d=$(mktemp -d); cd "$d"
SIM="-c:v libx264 -preset medium -b:v 2500k -maxrate 3000k -bufsize 5000k -g 60 -pix_fmt yuv420p"
q() { ffmpeg -hide_banner -i "$1" -i clean.mp4 -lavfi "[0][1]ssim;[0][1]psnr" -f null - 2>&1 | grep -oE "(All:[0-9.]+|average:[0-9.]+)" | tr '\n' ' '; echo; }
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "mandelbrot=size=1080x1920:rate=30" -f lavfi -i "testsrc2=size=1080x1920:rate=30" \
  -filter_complex "[0][1]blend=all_mode=overlay:all_opacity=0.5,eq=brightness=-0.12:gamma=0.85,format=yuv420p" -t 6 -c:v libx264 -crf 8 -preset veryfast clean.mp4
ffmpeg -hide_banner -loglevel error -y -i clean.mp4 -vf "noise=alls=14:allf=t+u,format=yuv420p" -c:v libx264 -crf 10 -preset veryfast noisy.mp4
ffmpeg -hide_banner -loglevel error -y -i noisy.mp4 $SIM a.mp4
ffmpeg -hide_banner -loglevel error -y -i noisy.mp4 -vf "bilateral=sigmaS=1.5:sigmaR=0.055,format=yuv420p" $SIM b.mp4
printf "original  -> TikTok: "; q a.mp4
printf "survival  -> TikTok: "; q b.mp4
rm -rf "$d"
