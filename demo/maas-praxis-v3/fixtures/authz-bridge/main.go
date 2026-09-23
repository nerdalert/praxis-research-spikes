package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	corev3 "github.com/envoyproxy/go-control-plane/envoy/config/core/v3"
	commonratelimitv3 "github.com/envoyproxy/go-control-plane/envoy/extensions/common/ratelimit/v3"
	authv3 "github.com/envoyproxy/go-control-plane/envoy/service/auth/v3"
	ratelimitv3 "github.com/envoyproxy/go-control-plane/envoy/service/ratelimit/v3"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
)

type decision struct {
	Decision     string `json:"decision"`
	Status       int    `json:"status"`
	UserID       string `json:"userid,omitempty"`
	Subscription string `json:"subscription,omitempty"`
	Reason       string `json:"reason,omitempty"`
}

type policyRoute struct {
	Name            string `json:"name"`
	Model           string `json:"model"`
	Backend         string `json:"backend"`
	HostScope       string `json:"authorino_host_scope"`
	LimitDomain     string `json:"limitador_domain"`
	DescriptorKey   string `json:"descriptor_key"`
	DescriptorValue string `json:"descriptor_value"`
}

type policyConfig struct {
	Revision string        `json:"revision,omitempty"`
	Routes   []policyRoute `json:"routes"`
}

type policySnapshot struct {
	routes   []policyRoute
	revision string
}

type policyStore struct {
	mu   sync.RWMutex
	data policySnapshot
}

func (s *policyStore) get() policySnapshot {
	s.mu.RLock()
	defer s.mu.RUnlock()
	routes := append([]policyRoute(nil), s.data.routes...)
	return policySnapshot{routes: routes, revision: s.data.revision}
}

func (s *policyStore) set(snapshot policySnapshot) {
	s.mu.Lock()
	s.data = snapshot
	s.mu.Unlock()
}

func loadPolicies(path string) (policySnapshot, error) {
	if path == "" {
		return policySnapshot{}, nil
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return policySnapshot{}, err
	}
	var cfg policyConfig
	if err := json.Unmarshal(b, &cfg); err != nil {
		return policySnapshot{}, err
	}
	for _, p := range cfg.Routes {
		if p.Model == "" || p.HostScope == "" || p.LimitDomain == "" || p.DescriptorKey == "" || p.DescriptorValue == "" {
			return policySnapshot{}, fmt.Errorf("incomplete policy route %q", p.Name)
		}
	}
	revision := cfg.Revision
	if revision == "" {
		digest := sha256.Sum256(b)
		revision = hex.EncodeToString(digest[:])
	}
	return policySnapshot{routes: cfg.Routes, revision: revision}, nil
}

func selectPolicy(routes []policyRoute, model string) (policyRoute, bool) {
	for _, p := range routes {
		// MaaS's stable identity is namespace/name.  The OpenAI request model
		// for an ExternalModel is the client-visible name, so accept only the
		// unambiguous final path segment as its transport alias.
		if p.Model == model || strings.HasSuffix(p.Model, "/"+model) {
			return p, true
		}
	}
	return policyRoute{}, false
}

func headerMap(h http.Header) map[string]string {
	out := map[string]string{}
	for k, v := range h {
		if len(v) > 0 {
			out[strings.ToLower(k)] = v[0]
		}
	}
	return out
}

func headerValue(headers []*corev3.HeaderValueOption, name string) string {
	for _, h := range headers {
		if strings.EqualFold(h.Header.GetKey(), name) {
			return h.Header.GetValue()
		}
	}
	return ""
}

func authCheck(ctx context.Context, conn *grpc.ClientConn, r *http.Request, body []byte, hostScope string) (*authv3.CheckResponse, error) {
	// Authorino selects the generated AuthConfig from the HTTP host. Praxis is
	// calling this run-owned adapter directly, so the adapter must present the
	// selected generated host scope rather than its own Service DNS name.
	host := hostScope
	if host == "" {
		host = r.Host
		if host == "" {
			host = "maas-default-gateway"
		}
	}
	// Praxis promotes the model into this internal callout header before the
	// request-phase callout runs. A direct body fallback keeps the adapter useful
	// for the retained request-body diagnostic, but this Service is run-owned and
	// is not exposed to clients; callers cannot set this header on the Praxis
	// listener because the model_to_header filter replaces it.
	model := ""
	var payload struct {
		Model string `json:"model"`
	}
	if json.Unmarshal(body, &payload) == nil {
		model = strings.TrimSpace(payload.Model)
	}
	if model == "" {
		model = strings.TrimSpace(r.Header.Get("X-Gateway-Model-Name"))
	}
	headers := headerMap(r.Header)
	delete(headers, "x-gateway-model-name")
	if model != "" {
		headers["x-gateway-model-name"] = model
	}
	req := &authv3.CheckRequest{Attributes: &authv3.AttributeContext{
		Request: &authv3.AttributeContext_Request{Http: &authv3.AttributeContext_HttpRequest{
			Method: r.Method, Host: host, Path: r.URL.RequestURI(), Protocol: r.Proto,
			Headers: headers, Body: string(body), Scheme: "http",
		}},
		ContextExtensions: map[string]string{"host": hostScope},
	}}
	return authv3.NewAuthorizationClient(conn).Check(ctx, req)
}

func limitCheck(ctx context.Context, conn *grpc.ClientConn, userID, domain, descriptorKey, descriptorValue string) (bool, error) {
	// These names and the policy namespace are read from the generated
	// TokenRateLimitPolicy and Limitador CR, not invented by the proxy.
	req := &ratelimitv3.RateLimitRequest{
		Domain: domain,
		Descriptors: []*commonratelimitv3.RateLimitDescriptor{{Entries: []*commonratelimitv3.RateLimitDescriptor_Entry{
			{Key: descriptorKey, Value: descriptorValue},
			{Key: "auth.identity.userid", Value: userID},
		}}},
	}
	resp, err := ratelimitv3.NewRateLimitServiceClient(conn).ShouldRateLimit(ctx, req)
	if err != nil {
		return false, err
	}
	return resp.GetOverallCode() == ratelimitv3.RateLimitResponse_OK, nil
}

func main() {
	authorinoAddr := getenv("AUTHORINO_ADDR", "authorino-authorino-authorization.kuadrant-system.svc.cluster.local:50051")
	limitadorAddr := getenv("LIMITADOR_ADDR", "limitador-limitador.kuadrant-system.svc.cluster.local:8081")
	policyPath := os.Getenv("POLICY_CONFIG")
	initial, err := loadPolicies(policyPath)
	if err != nil {
		log.Fatalf("load policy config: %v", err)
	}
	store := &policyStore{}
	store.set(initial)
	if policyPath != "" {
		go func() {
			ticker := time.NewTicker(500 * time.Millisecond)
			defer ticker.Stop()
			lastRevision := initial.revision
			for range ticker.C {
				candidate, reloadErr := loadPolicies(policyPath)
				if reloadErr != nil {
					if os.IsNotExist(reloadErr) {
						store.set(policySnapshot{})
						if lastRevision != "missing" {
							log.Printf("policy revision=missing serving_routes=0 result=fail-closed")
							lastRevision = "missing"
						}
					} else {
						log.Printf("policy reload rejected revision=%s error=%v retaining_last_known_good=%s", lastRevision, reloadErr, lastRevision)
					}
					continue
				}
				if candidate.revision != lastRevision {
					store.set(candidate)
					log.Printf("policy revision=%s serving_routes=%d result=accepted", candidate.revision, len(candidate.routes))
					lastRevision = candidate.revision
				}
			}
		}()
	}
	// Legacy variables remain available for the retained-cluster regression, but
	// a cold run must provide POLICY_CONFIG. The generated table is deliberately
	// data-only: entitlement and API-key semantics remain in Authorino/MaaS.
	hostScope := getenv("AUTH_HOST_SCOPE", "")
	limitDomain := getenv("LIMIT_DOMAIN", "")
	descriptorKey := getenv("LIMIT_DESCRIPTOR_KEY", "")
	descriptorValue := getenv("LIMIT_DESCRIPTOR_VALUE", "1")
	aconn, err := grpc.NewClient(authorinoAddr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		log.Fatal(err)
	}
	defer aconn.Close()
	lconn, err := grpc.NewClient(limitadorAddr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		log.Fatal(err)
	}
	defer lconn.Close()

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/health" {
			fmt.Fprintln(w, "ok")
			return
		}
		body, e := io.ReadAll(r.Body)
		if e != nil {
			http.Error(w, "body read failed", 400)
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
		defer cancel()
		// The two run-owned routes share this deliberately small POC adapter.
		// Policy identity still comes from the generated MaaS objects below; the
		// model header only selects which generated fixture is consulted.
		activeScope, activeDomain, activeKey, activeValue := hostScope, limitDomain, descriptorKey, descriptorValue
		modelHeader := strings.ToLower(r.Header.Get("X-Gateway-Model-Name"))
		if modelHeader == "" {
			var payload struct {
				Model string `json:"model"`
			}
			if json.Unmarshal(body, &payload) == nil {
				modelHeader = strings.ToLower(strings.TrimSpace(payload.Model))
			}
		}
		snapshot := store.get()
		policies := snapshot.routes
		// An explicit empty generated policy means that no current MaaS route
		// is eligible. Do not fall back to legacy fixture variables: fail closed
		// before EPP or provider contact.
		if policyPath != "" && len(policies) == 0 {
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(decision{Decision: "forbidden", Status: 403, Reason: "no eligible generated route"})
			log.Printf("decision path=%s result=forbidden status=403 stage=route reason=no_eligible_route policy_revision=%s", r.URL.Path, snapshot.revision)
			return
		}
		if len(policies) > 0 {
			model := modelHeader
			selected, ok := selectPolicy(policies, model)
			if !ok {
				w.Header().Set("Content-Type", "application/json")
				json.NewEncoder(w).Encode(decision{Decision: "forbidden", Status: 403, Reason: "unknown model route"})
				log.Printf("decision path=%s result=forbidden status=403 stage=route model=%q policy_revision=%s", r.URL.Path, model, snapshot.revision)
				return
			}
			activeScope, activeDomain, activeKey, activeValue = selected.HostScope, selected.LimitDomain, selected.DescriptorKey, selected.DescriptorValue
		}
		authResp, e := authCheck(ctx, aconn, r, body, activeScope)
		if e != nil {
			log.Printf("decision path=%s result=error stage=authorino error=%v", r.URL.Path, e)
			http.Error(w, `{"decision":"error","status":503}`, 503)
			return
		}
		code := codes.Code(authResp.GetStatus().GetCode())
		if code != codes.OK {
			log.Printf("authorino denial code=%s message=%q host_scope=%q model=%q policy_revision=%s", code.String(), authResp.GetStatus().GetMessage(), activeScope, modelHeader, snapshot.revision)
			d := decision{Decision: "forbidden", Status: 403, Reason: code.String()}
			if code == codes.Unauthenticated {
				d.Decision, d.Status = "unauthenticated", 401
			}
			w.Header().Set("Content-Type", "application/json")
			log.Printf("decision path=%s result=%s status=%d stage=authorino policy_revision=%s", r.URL.Path, d.Decision, d.Status, snapshot.revision)
			json.NewEncoder(w).Encode(d)
			return
		}
		userid := headerValue(authResp.GetOkResponse().GetHeaders(), "X-MaaS-Username")
		subscription := headerValue(authResp.GetOkResponse().GetHeaders(), "X-MaaS-Subscription")
		if userid == "" {
			userid = "unknown"
		}
		allowed, e := limitCheck(ctx, lconn, userid, activeDomain, activeKey, activeValue)
		if e != nil {
			log.Printf("decision path=%s result=error stage=limitador error=%v", r.URL.Path, e)
			http.Error(w, `{"decision":"error","status":503}`, 503)
			return
		}
		if !allowed {
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(decision{Decision: "quota", Status: 429, UserID: userid, Subscription: subscription})
			log.Printf("decision path=%s result=quota status=429 stage=limitador policy_revision=%s", r.URL.Path, snapshot.revision)
			return
		}
		result := "allowed"
		if len(policies) > 0 {
			if selected, ok := selectPolicy(policies, modelHeader); ok {
				switch selected.Backend {
				case "service":
					result = "allowed-sim"
				case "external":
					result = "allowed-external"
				}
			}
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(decision{Decision: result, Status: 200, UserID: userid, Subscription: subscription})
		log.Printf("decision path=%s result=%s status=200 stage=limitador model=%q body_bytes=%d policy_revision=%s", r.URL.Path, result, modelHeader, len(body), snapshot.revision)
	})
	log.Println("authz bridge listening on :8080")
	log.Fatal(http.ListenAndServe(":8080", nil))
}

func getenv(k, fallback string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return fallback
}
