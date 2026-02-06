// Acme App - hatch lifecycle hooks (TypeScript)
// Place this alongside hatch.conf in the project root
// Set HOOKS_FILE="hatch.hooks.ts" in hatch.conf
//
// All HATCH_* env vars are available via process.env:
//   HATCH_PORT_<service>  — allocated port (hyphens/dots become underscores)
//   PORT_<service>        — same, shorthand
//   PROJECT_NAME, WORKSPACE_NAME, PACKAGE_MANAGER, etc.

const TOKEN = process.env.CONTEMBER_API_TOKEN || "0000000000000000000000000000000000000000";
const ACTIONS_SECRET_KEY = process.env.CONTEMBER_ACTIONS_SECRET_KEY || "2222222222222222222222222222222222222222";

function resolvePort(service: string): string {
  const safe = service.replace(/[-.]/g, "_");
  const port = process.env[`HATCH_PORT_${safe}`];
  if (!port) throw new Error(`No port allocated for service: ${service}`);
  return port;
}

export async function acme_app_import(exportFile: string) {
  const port = resolvePort("contember-engine");
  const { readFileSync } = await import("fs");
  const body = readFileSync(exportFile);

  const res = await fetch(`http://localhost:${port}/import`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${TOKEN}`,
      "Content-Type": "application/x-ndjson",
      "Content-Encoding": "gzip",
    },
    body,
  });

  if (!res.ok) {
    throw new Error(`Import failed: ${res.status} ${res.statusText}`);
  }
}

export async function acme_app_export(exportPath: string) {
  const { execFileSync } = await import("child_process");
  const pkgCmd = process.env.PACKAGE_MANAGER === "bun" ? "bunx" : "npx";
  execFileSync(pkgCmd, ["contember", "data:export", "--output", exportPath], {
    stdio: "inherit",
  });
}

export async function acme_app_setup() {
  const port = resolvePort("contember-engine");
  const apiUrl = `http://localhost:${port}`;
  const contentUrl = `${apiUrl}/content/acme-app-management/live`;
  const actionsUrl = `${apiUrl}/actions/acme-app-management`;
  const tenantUrl = `${apiUrl}/tenant`;

  console.log("=== Acme App: Project-specific setup ===");

  // Step 1: Get tenant person ID
  console.log("[info] Getting tenant person ID...");
  const tenantRes = await fetch(tenantUrl, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${TOKEN}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ query: "query { me { person { id } } }" }),
  });
  const tenantData = await tenantRes.json();
  const tenantPersonId = tenantData?.data?.me?.person?.id;

  if (!tenantPersonId) {
    console.warn(`[warn] Could not get tenant person ID`);
    console.warn(`[warn] Response: ${JSON.stringify(tenantData)}`);
    return;
  }
  console.log(`[info] Tenant person ID: ${tenantPersonId}`);

  // Step 2: Create Person record
  console.log("[info] Creating Person record...");
  const personRes = await fetch(contentUrl, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${TOKEN}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      query: `mutation { createPerson(data: { personId: "${tenantPersonId}" }) { ok node { id } } }`,
    }),
  });
  const personData = await personRes.json();
  let personId = personData?.data?.createPerson?.node?.id;

  if (!personId) {
    const getRes = await fetch(contentUrl, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${TOKEN}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        query: `query { getPerson(by: { personId: "${tenantPersonId}" }) { id } }`,
      }),
    });
    const getData = await getRes.json();
    personId = getData?.data?.getPerson?.id;
  }

  if (personId) {
    console.log(`[info] Person ID: ${personId}`);

    // Step 3: Create User record
    console.log("[info] Creating User record...");
    await fetch(contentUrl, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${TOKEN}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        query: `mutation { createUser(data: { person: { connect: { id: "${personId}" } }, firstName: "Contember", lastName: "Admin" }) { ok } }`,
      }),
    });
    console.log("[ok] User setup complete");
  } else {
    console.warn("[warn] Could not create/find Person record");
  }

  // Step 4: Set system variables
  console.log("[info] Setting system variables...");
  const workerPort = resolvePort("worker");
  const dockerHost =
    process.platform === "darwin" ? "host.docker.internal" : "172.17.0.1";

  const varsRes = await fetch(actionsUrl, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${TOKEN}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      query: `mutation { setVariables(args: { variables: [{ name: "apiKey", value: "${ACTIONS_SECRET_KEY}" }, { name: "baseUrl", value: "http://${dockerHost}:${workerPort}" }] }) { ok } }`,
    }),
  });
  const varsData = await varsRes.json();

  if (varsData?.data?.setVariables?.ok) {
    console.log("[ok] Variables set successfully");
  } else {
    console.warn(`[warn] Variables response: ${JSON.stringify(varsData)}`);
  }

  console.log("[ok] Acme App setup complete");
}
