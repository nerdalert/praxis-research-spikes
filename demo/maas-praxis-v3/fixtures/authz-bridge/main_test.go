package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadPoliciesDerivesRevisionWhenAbsent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "policy.json")
	if err := os.WriteFile(path, []byte(`{"routes":[{"name":"m","model":"ns/m","authorino_host_scope":"scope","limitador_domain":"domain","descriptor_key":"key","descriptor_value":"1"}]}`), 0600); err != nil {
		t.Fatal(err)
	}
	snapshot, err := loadPolicies(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot.routes) != 1 || len(snapshot.revision) != 64 {
		t.Fatalf("unexpected snapshot: %+v", snapshot)
	}
}

func TestLoadPoliciesRejectsIncompleteRoute(t *testing.T) {
	path := filepath.Join(t.TempDir(), "policy.json")
	if err := os.WriteFile(path, []byte(`{"revision":"r","routes":[{"model":"ns/m"}]}`), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := loadPolicies(path); err == nil {
		t.Fatal("expected incomplete route to fail closed")
	}
}

func TestSelectPolicyAcceptsOnlyStableTransportAlias(t *testing.T) {
	routes := []policyRoute{{Model: "tenant/external"}}
	if _, ok := selectPolicy(routes, "external"); !ok {
		t.Fatal("expected client-visible model alias to resolve")
	}
	if _, ok := selectPolicy(routes, "not-external"); ok {
		t.Fatal("unexpected ambiguous model alias")
	}
}
