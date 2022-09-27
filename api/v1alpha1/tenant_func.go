// Copyright 2020-2021 Clastix Labs
// SPDX-License-Identifier: Apache-2.0

package v1alpha1

import (
	"sort"

	corev1 "k8s.io/api/core/v1"
)

func (in *Tenant) IsCordoned() bool {
	if v, ok := in.Labels["capsule.clastix.io/cordon"]; ok && v == "enabled" {
		return true
	}

	return false
}

func (in *Tenant) IsFull() bool {
	// we don't have limits on assigned Namespaces
	if in.Spec.NamespaceQuota == nil {
		return false
	}

	return len(in.Status.Namespaces) >= int(*in.Spec.NamespaceQuota)
}

func (in *Tenant) AssignNamespaces(namespaces []corev1.Namespace) {
	var l []string

	for _, ns := range namespaces {
		if ns.Status.Phase == corev1.NamespaceActive {
			l = append(l, ns.GetName())
		}
	}

	sort.Strings(l)

	in.Status.Namespaces = l
	in.Status.Size = uint(len(l))
}
