package handlers

import (
	"encoding/json"
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
	//
	// v14: each user content item is a UX frame whose value is a JSON content
	// item — {"type":"image","uri":...} etc. The concrete kind lives in
	// "type", not in the tag.
	frames := make([]tlv.Frame, 0, len(args.Media)+2)
	for _, item := range args.Media {
		var kind string
		switch item.MediaType {
		case "image":
			kind = "image"
		case "audio":
			kind = "audio"
		case "video":
			kind = "video"
		case "document":
			kind = "document"
		default:
			return fmt.Errorf("Unknown media type: %s", item.MediaType)
		}
		body, err := json.Marshal(tlv.ContentData{
			ContentItem: tlv.ContentItem{Type: kind, URI: item.URI},
		})
		if err != nil {
			return err
		}
		frames = append(frames, tlv.Frame{Tag: tlv.TagUserX, Value: string(body)})
	}
	if args.Text != "" {
		body, err := json.Marshal(tlv.ContentData{
			ContentItem: tlv.ContentItem{Type: "text", Text: args.Text},
		})
		if err != nil {
			return err
		}
		frames = append(frames, tlv.Frame{Tag: tlv.TagUserX, Value: string(body)})
	}
	frames = append(frames, tlv.Frame{Tag: tlv.TagUserEnd, Value: ""})
	if err := s.WriteFrames(frames); err != nil {
		return err
	}
	return writeResult(w, nil)
}
