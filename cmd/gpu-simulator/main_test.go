package main

import "testing"

// The simulator had no tests at all until the resource name stopped being a constant.
//
// That was tolerable while there was exactly one name and one socket: the DaemonSet either worked or the
// node advertised nothing, and the failure was loud. It stops being tolerable the moment two instances run
// on one node, because the way that breaks is quiet — the second instance removes the first one's socket on
// startup and inherits its registration, and the node goes on advertising a plausible number.

// The historical deployment must render byte-identically, or every existing kind cluster changes underneath
// an experiment that was not about sockets.
func TestTheDefaultResourceKeepsItsHistoricalSocket(t *testing.T) {
	if got := socketNameFor(defaultResourceName); got != defaultSocketName {
		t.Fatalf("socketNameFor(%q) = %q, want the historical %q", defaultResourceName, got, defaultSocketName)
	}
}

// A profile-shaped name cannot be used as a file name as it stands.
//
// "nvidia.com/mig-1g.5gb" carries a slash, which would make filepath.Join treat it as a directory that does
// not exist, and dots, which are merely ugly. The point of the assertion is the slash: a socket path with an
// unescaped one fails at listen time, after the plugin has already removed what it thought was its own
// stale socket.
func TestAProfileNameBecomesAUsableSocketName(t *testing.T) {
	got := socketNameFor("nvidia.com/mig-1g.5gb")
	want := "gpu-simulator-nvidia-com-mig-1g-5gb.sock"
	if got != want {
		t.Fatalf("socketNameFor = %q, want %q", got, want)
	}
}

// Two different resources must not collide on one socket.
//
// This is the property that makes several instances per node safe, and it is asserted rather than assumed
// because the collision is silent: whichever instance starts second deletes the other's socket and takes
// over the kubelet's idea of who serves that endpoint.
func TestDifferentResourcesGetDifferentSockets(t *testing.T) {
	names := []string{
		defaultResourceName,
		"nvidia.com/mig-1g.5gb",
		"nvidia.com/mig-2g.10gb",
	}
	seen := map[string]string{}
	for _, name := range names {
		socket := socketNameFor(name)
		if other, clash := seen[socket]; clash {
			t.Fatalf("%q and %q both want socket %q", other, name, socket)
		}
		seen[socket] = name
	}
}

// envOr is the one piece of configuration plumbing every override goes through.
//
// An empty variable must read as unset: a DaemonSet that sets FAKE_RESOURCE_NAME to "" should get the
// default rather than an empty resource name, which the kubelet would reject in a way that looks like a
// registration bug rather than a configuration one.
func TestAnEmptyVariableFallsBackToTheDefault(t *testing.T) {
	t.Setenv("FAKE_RESOURCE_NAME", "")
	if got := envOr("FAKE_RESOURCE_NAME", defaultResourceName); got != defaultResourceName {
		t.Fatalf("envOr with an empty value = %q, want %q", got, defaultResourceName)
	}

	t.Setenv("FAKE_RESOURCE_NAME", "nvidia.com/mig-1g.5gb")
	if got := envOr("FAKE_RESOURCE_NAME", defaultResourceName); got != "nvidia.com/mig-1g.5gb" {
		t.Fatalf("envOr did not return the set value, got %q", got)
	}
}
