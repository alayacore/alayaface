package handlers

import (
	"fmt"
	"log"
	"net/http"

	"alayaface/src-go/internal/mcp"
)

// StartMcpAuthFlow starts the MCP OAuth flow: launch callback server,
// fill URL, open browser. Returns the filled URL.
func StartMcpAuthFlow(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		SessionID  string `json:"sessionId"`
		ServerName string `json:"serverName"`
		AuthURL    string `json:"authUrl"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}
	return startMcpAuth(h, args, true, w)
}

// FillMcpAuthUrl fills the MCP auth URL without opening the browser.
// Returns the filled URL for the frontend to copy.
func FillMcpAuthUrl(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		SessionID  string `json:"sessionId"`
		ServerName string `json:"serverName"`
		AuthURL    string `json:"authUrl"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}
	return startMcpAuth(h, args, false, w)
}

func startMcpAuth(h *Handler, args struct {
	SessionID  string `json:"sessionId"`
	ServerName string `json:"serverName"`
	AuthURL    string `json:"authUrl"`
}, openBrowser bool, w http.ResponseWriter) error {
	s, err := h.Sessions.Get(args.SessionID)
	if err != nil {
		return err
	}

	filledURL, err := mcp.StartAuthFlow(args.ServerName, args.AuthURL, openBrowser, func(res mcp.Result) {
		if res.Code != nil {
			input := fmt.Sprintf("%s %s %s", args.ServerName, *res.Code, res.RedirectURI)
			log.Printf("[mcp_auth] Sending mcp_confirm: %s", input)
			if _, err := s.SendCmd("mcp_confirm", input); err != nil {
				log.Printf("[mcp_auth] mcp_confirm failed: %v", err)
			}
		} else {
			log.Printf("[mcp_auth] Auth failed/cancelled — sending mcp_decline %s", args.ServerName)
			if _, err := s.SendCmd("mcp_decline", args.ServerName); err != nil {
				log.Printf("[mcp_auth] mcp_decline failed: %v", err)
			}
		}
	})
	if err != nil {
		return err
	}
	return writeResult(w, filledURL)
}
