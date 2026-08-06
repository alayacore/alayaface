package handlers

import (
	"encoding/base64"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// DirEntry is a directory listing entry (Rust renames to isDir).
type DirEntry struct {
	Name  string `json:"name"`
	IsDir bool   `json:"isDir"`
}

// FsListDir lists the contents of a directory: ".." first, then dirs
// (case-insensitive), then files.
func FsListDir(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		Path string `json:"path"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}
	fi, err := os.Stat(args.Path)
	if err != nil {
		if os.IsNotExist(err) {
			// A missing directory is an EMPTY list, not an error: the
			// plans dir may not exist until the first plan is created,
			// and callers (plan meta index rebuild, manager, browser)
			// treat a missing directory as "nothing here". Mirrors the
			// Rust backend.
			return writeJSON(w, []DirEntry{})
		}
		return err
	}
	if !fi.IsDir() {
		return fmt.Errorf("Not a directory: %s", args.Path)
	}

	entries, err := os.ReadDir(args.Path)
	if err != nil {
		return fmt.Errorf("Cannot read directory: %w", err)
	}

	result := make([]DirEntry, 0, len(entries)+1)
	if args.Path != "/" {
		result = append(result, DirEntry{Name: "..", IsDir: true})
	}

	var dirs, files []DirEntry
	for _, e := range entries {
		de := DirEntry{Name: e.Name(), IsDir: e.IsDir()}
		if e.IsDir() {
			dirs = append(dirs, de)
		} else {
			files = append(files, de)
		}
	}
	sort.Slice(dirs, func(i, j int) bool {
		return strings.ToLower(dirs[i].Name) < strings.ToLower(dirs[j].Name)
	})
	sort.Slice(files, func(i, j int) bool {
		return strings.ToLower(files[i].Name) < strings.ToLower(files[j].Name)
	})
	result = append(result, dirs...)
	result = append(result, files...)
	return writeJSON(w, result)
}

// FsHomeDir returns the user's home directory path.
func FsHomeDir(h *Handler, w http.ResponseWriter, r *http.Request) error {
	home := os.Getenv("HOME")
	if home == "" {
		home = os.Getenv("USERPROFILE")
	}
	if home == "" {
		return fmt.Errorf("Cannot determine home directory")
	}
	return writeResult(w, home)
}

// ResolvedPath is the result of fs_resolve_path.
type ResolvedPath struct {
	Resolved string `json:"resolved"`
	Exists   bool   `json:"exists"`
	IsDir    bool   `json:"isDir"`
}

// FsResolvePath resolves a path (handles ~, ., ..) and returns info.
func FsResolvePath(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		Path string `json:"path"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}
	path := args.Path
	var resolved string
	if strings.HasPrefix(path, "~") {
		home := os.Getenv("HOME")
		if home == "" {
			home = os.Getenv("USERPROFILE")
		}
		if home == "" {
			home = "."
		}
		resolved = filepath.Join(home, path[1:])
	} else if strings.HasPrefix(path, "/") {
		resolved = path
	} else {
		cwd, _ := os.Getwd()
		resolved = filepath.Join(cwd, path)
	}

	normalized := ""
	if canon, err := filepath.Abs(resolved); err == nil {
		if canon2, err := filepath.EvalSymlinks(canon); err == nil {
			normalized = canon2
		} else {
			normalized = filepath.Clean(canon)
		}
	} else {
		normalized = filepath.Clean(resolved)
	}

	exists := false
	isDir := false
	if fi, err := os.Stat(normalized); err == nil {
		exists = true
		isDir = fi.IsDir()
	}
	return writeJSON(w, ResolvedPath{Resolved: normalized, Exists: exists, IsDir: isDir})
}

// guessMime guesses the MIME type from a file extension.
func guessMime(path string) string {
	ext := strings.ToLower(filepath.Ext(path))
	switch ext {
	case ".jpg", ".jpeg":
		return "image/jpeg"
	case ".png":
		return "image/png"
	case ".gif":
		return "image/gif"
	case ".webp":
		return "image/webp"
	case ".bmp":
		return "image/bmp"
	case ".svg":
		return "image/svg+xml"
	case ".mp3":
		return "audio/mpeg"
	case ".wav":
		return "audio/wav"
	case ".ogg", ".oga":
		return "audio/ogg"
	case ".flac":
		return "audio/flac"
	case ".m4a":
		return "audio/mp4"
	case ".mp4":
		return "video/mp4"
	case ".webm":
		return "video/webm"
	case ".avi":
		return "video/x-msvideo"
	case ".mov":
		return "video/quicktime"
	case ".mkv":
		return "video/x-matroska"
	case ".pdf":
		return "application/pdf"
	case ".txt", ".md":
		return "text/plain"
	case ".json":
		return "application/json"
	case ".csv":
		return "text/csv"
	case ".html", ".htm":
		return "text/html"
	case ".js":
		return "text/javascript"
	case ".ts":
		return "text/typescript"
	case ".rs":
		return "text/rust"
	case ".py":
		return "text/x-python"
	case ".go":
		return "text/x-go"
	case ".java":
		return "text/x-java"
	case ".c":
		return "text/x-c"
	case ".cpp", ".cc", ".cxx":
		return "text/x-c++"
	case ".h", ".hpp":
		return "text/x-header"
	case ".yaml", ".yml":
		return "text/yaml"
	case ".toml":
		return "text/toml"
	case ".xml":
		return "text/xml"
	default:
		return "application/octet-stream"
	}
}

// FsReadFileDataUri reads a file and returns it as a data URI string.
func FsReadFileDataUri(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		Path string `json:"path"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}
	data, err := os.ReadFile(args.Path)
	if err != nil {
		return fmt.Errorf("Cannot read file: %w", err)
	}
	mime := guessMime(args.Path)
	uri := fmt.Sprintf("data:%s;base64,%s", mime, base64.StdEncoding.EncodeToString(data))
	return writeResult(w, uri)
}

// FsWriteFileText writes a UTF-8 text file. CreateParents (default
// false) creates the parent directory chain first. Used by Plan Mode to
// save plan/run JSON. Mirrors Rust fs_write_file_text exactly.
func FsWriteFileText(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		Path          string `json:"path"`
		Content       string `json:"content"`
		CreateParents bool   `json:"createParents"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}
	if args.CreateParents {
		parent := filepath.Dir(args.Path)
		if parent != "" && parent != "." {
			if err := os.MkdirAll(parent, 0o755); err != nil {
				return fmt.Errorf("Cannot write file: %w", err)
			}
		}
	}
	if err := os.WriteFile(args.Path, []byte(args.Content), 0o644); err != nil {
		return fmt.Errorf("Cannot write file: %w", err)
	}
	return writeResult(w, nil)
}

// FsReadFileText reads a UTF-8 text file. Used by Plan Mode to load
// plan/run JSON. Mirrors Rust fs_read_file_text exactly.
func FsReadFileText(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		Path string `json:"path"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}
	text, err := os.ReadFile(args.Path)
	if err != nil {
		return fmt.Errorf("Cannot read file: %w", err)
	}
	return writeResult(w, string(text))
}

// FsDeleteFile deletes a file. Used by Plan Mode to remove saved plans.
// Mirrors Rust fs_delete_file exactly.
func FsDeleteFile(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		Path string `json:"path"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}
	fi, err := os.Stat(args.Path)
	if err != nil {
		if os.IsNotExist(err) {
			return fmt.Errorf("Cannot delete file: Path does not exist")
		}
		return fmt.Errorf("Cannot delete file: %w", err)
	}
	if fi.IsDir() {
		return fmt.Errorf("Cannot delete file: Is a directory")
	}
	if err := os.Remove(args.Path); err != nil {
		return fmt.Errorf("Cannot delete file: %w", err)
	}
	return writeResult(w, nil)
}
