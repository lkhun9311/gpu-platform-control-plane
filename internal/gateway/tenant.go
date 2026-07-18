/*
Copyright 2026.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package gateway

import (
	"context"
	"net/http"
	"strings"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/types"
)

// resolveTenant maps the request's Bearer API key to a tenant via the api-keys Secret.
//
// It returns ok=false for a missing or unknown key.
func (s *Server) resolveTenant(ctx context.Context, r *http.Request) (string, bool) {
	h := r.Header.Get("Authorization")
	// Split the header into scheme and credential on the first space.
	scheme, credential, found := strings.Cut(h, " ")
	// HTTP auth schemes are case-insensitive per RFC 7235, so compare with EqualFold.
	if !found || !strings.EqualFold(scheme, "Bearer") {
		return "", false
	}
	key := strings.TrimSpace(credential)
	if key == "" {
		return "", false
	}
	var sec corev1.Secret
	if err := s.Client.Get(ctx, types.NamespacedName{Name: s.APIKeySecret, Namespace: s.Namespace}, &sec); err != nil {
		return "", false
	}
	tenant, ok := sec.Data[key]
	return string(tenant), ok && len(tenant) > 0
}
