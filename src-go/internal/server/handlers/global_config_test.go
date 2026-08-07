package handlers

import (
	"encoding/json"
	"os"
	"testing"

	"alayaface/src-go/internal/dirs"
)

func TestGlobalConfigMissingYieldsDefault(t *testing.T) {
	isolatedHome(t, func() {
		cfg, err := readGlobalConfig()
		if err != nil {
			t.Fatal(err)
		}
		if cfg.RecursionLimit != DefaultRecursionLimit {
			t.Errorf("recursion_limit = %d, want %d", cfg.RecursionLimit, DefaultRecursionLimit)
		}
	})
}

func TestNormalizeRecursionLimit(t *testing.T) {
	cases := []struct{ in, want int }{
		{0, DefaultRecursionLimit},
		{-3, DefaultRecursionLimit},
		{1, 1},
		{8, 8},
		{64, 64},
	}
	for _, c := range cases {
		if got := NormalizeRecursionLimit(c.in); got != c.want {
			t.Errorf("NormalizeRecursionLimit(%d) = %d, want %d", c.in, got, c.want)
		}
	}
}

func TestGlobalConfigSyncRoundtrips(t *testing.T) {
	isolatedHome(t, func() {
		rr := call(t, SyncGlobalConfig, map[string]any{
			"config": `{"recursion_limit": 12}`,
		})
		if rr.Code != 200 {
			t.Fatalf("sync status = %d, body %s", rr.Code, rr.Body.String())
		}
		// The normalized config is returned so the frontend adopts it.
		var out map[string]any
		if err := json.Unmarshal(rr.Body.Bytes(), &out); err != nil {
			t.Fatal(err)
		}
		if out["recursion_limit"] != float64(12) {
			t.Errorf("sync returned %v, want recursion_limit 12", out)
		}
		cfg, err := readGlobalConfig()
		if err != nil {
			t.Fatal(err)
		}
		if cfg.RecursionLimit != 12 {
			t.Errorf("recursion_limit = %d, want 12", cfg.RecursionLimit)
		}
	})
}

func TestGlobalConfigSyncRejectsInvalid(t *testing.T) {
	isolatedHome(t, func() {
		// A bad value must be rejected and must not clobber the file.
		if err := callErr(t, SyncGlobalConfig, map[string]any{
			"config": `{"recursion_limit": "many"}`,
		}); err == nil {
			t.Error("expected error for non-numeric recursion_limit")
		}
		if err := callErr(t, SyncGlobalConfig, map[string]any{
			"config": `{not json`,
		}); err == nil {
			t.Error("expected error for invalid JSON")
		}
		if _, err := os.Stat(dirs.GlobalConfigFile()); !os.IsNotExist(err) {
			t.Errorf("invalid sync must not create global.conf (err=%v)", err)
		}
	})
}

func TestGetGlobalConfigJSONShape(t *testing.T) {
	isolatedHome(t, func() {
		rr := call(t, GetGlobalConfig, map[string]any{})
		var out map[string]any
		if err := json.Unmarshal(rr.Body.Bytes(), &out); err != nil {
			t.Fatal(err)
		}
		if out["recursion_limit"] != float64(DefaultRecursionLimit) {
			t.Errorf("get returned %v, want recursion_limit %d", out, DefaultRecursionLimit)
		}
	})
}
