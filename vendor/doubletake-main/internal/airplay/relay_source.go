// AirPlay Splitter additions to doubletake (LGPL-3.0-or-later, same as upstream).

package airplay

import (
	"fmt"
	"sync/atomic"
)

// RelayAudioPort, when nonzero, replaces the test tone with 16-bit PCM RTP
// (L16, 44.1 kHz stereo, AirPlay's native rate) received on 127.0.0.1:RelayAudioPort. The app sends it
// from ScreenCaptureKit audio; UxPlay can send it with -artp.
var RelayAudioPort int

// VideoOnlyAudioFallback lets a receiver that only accepts AAC-ELD (which
// needs FDK-AAC, not bundled) connect without audio instead of failing.
var VideoOnlyAudioFallback bool

func relayAudioSourceArgs(port int) []string {
	return []string{
		"udpsrc", "address=127.0.0.1", fmt.Sprintf("port=%d", port),
		"caps=application/x-rtp,media=audio,clock-rate=44100,encoding-name=L16,channels=2,payload=96",
		"!", "rtpjitterbuffer", "latency=40", "drop-on-latency=true",
		"!", "rtpL16depay",
		// Keep a live, continuous stream when the Mac is silent (ScreenCaptureKit
		// sends nothing then), so receivers keep their audio clock running.
		"!", "audiorate", "skip-to-first=true",
	}
}

// dropH264SEI is set once the VideoToolbox encoder is selected; see the
// packetizer. Other encoders keep upstream's SEI passthrough.
var dropH264SEI atomic.Bool

// RelayRTPPort, when nonzero, replaces the synthetic test source with H.264 RTP
// received on 127.0.0.1:RelayRTPPort. UxPlay produces that stream with:
//
//	uxplay -vrtp "config-interval=1 ! udpsink host=127.0.0.1 port=5600"
//
// Set it before preparing capture; the daemon's -test path then relays instead.
var RelayRTPPort int

// relaySourceStages depayloads and decodes the relayed stream so the regular
// doubletake encoder path (scale to each receiver's canvas, fixed keyframe
// interval) applies unchanged.
func relaySourceStages(port, fps int) (gstStage, []gstStage) {
	source := gstStage{
		"udpsrc",
		"address=127.0.0.1",
		fmt.Sprintf("port=%d", port),
		"caps=application/x-rtp,media=video,clock-rate=90000,encoding-name=H264,payload=96",
	}
	return source, []gstStage{
		{"rtpjitterbuffer", "latency=60", "drop-on-latency=true"},
		{"rtph264depay"},
		{"h264parse"},
		{"decodebin"},
		// The Mac sends frames only when the screen changes. videorate repeats
		// the last slide so receivers see a steady cadence and never time out.
		{"videorate"},
		{fmt.Sprintf("video/x-raw,framerate=%d/1", fps)},
		lowLatencyVideoQueueStage(),
	}
}
