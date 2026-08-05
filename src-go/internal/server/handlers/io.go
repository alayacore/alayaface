package handlers

import (
	"fmt"
	"net/http"

	"alayaface/src-go/internal/tlv"
)

// MediaItem mirrors the Rust MediaItem (serde keeps snake_case).
type MediaItem struct {
	MediaType string `json:"media_type"`
	URI       string `json:"uri"`
}

// SendPrompt sends a user message (with optional media) to a session,
// ending with a UE flush frame. Port of commands/io.rs alayacore_send_prompt.
func SendPrompt(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		SessionID string      `json:"sessionId"`
		Text      string      `json:"text"`
		Media     []MediaItem `json:"media"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}

	s, err := h.Sessions.Get(args.SessionID)
	if err != nil {
		return err
	}
	if !s.Connected() {
		return fmt.Errorf("Session is disconnected")
	}

	// Build the whole message (media + text + UE) and write it under a
	// single stdin lock so a concurrent CI command cannot interleave.
	frames := make([]tlv.Frame, 0, len(args.Media)+2)
	for _, item := range args.Media {
		var tag string
		switch item.MediaType {
		case "image":
			tag = tlv.TagUserImage
		case "audio":
			tag = tlv.TagUserAudio
		case "video":
			tag = tlv.TagUserVideo
		case "document":
			tag = tlv.TagUserDoc
		default:
			return fmt.Errorf("Unknown media type: %s", item.MediaType)
		}
		frames = append(frames, tlv.Frame{Tag: tag, Value: item.URI})
	}
	if args.Text != "" {
		frames = append(frames, tlv.Frame{Tag: tlv.TagUserText, Value: args.Text})
	}
	frames = append(frames, tlv.Frame{Tag: tlv.TagUserEnd, Value: ""})
	if err := s.WriteFrames(frames); err != nil {
		return err
	}
	return writeResult(w, nil)
}
