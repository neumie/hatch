# Hatch Init: Contember Supplement

You are extending an existing hatch configuration with Contember-specific hooks. This prompt runs AFTER `hatch-init` has already created a working `hatch.conf`. Your job is to generate the `.hatch/` hooks infrastructure — TypeScript files that bridge Contember's tenant/content/actions APIs with the hatch setup lifecycle.

## Contember Architecture Reference

Contember has three API layers, all served by the `contember-engine` Docker service:

**Tenant layer** (`{engine}/tenant`) — Authentication and user management. The root superuser authenticates with token `0000000000000000000000000000000000000000` (40 hex zeros). Operations: `me { person { id } }`, `unmanagedInvite`, `addProjectMember`, `personByEmail`.

**Content layer** (`{engine}/content/{project-slug}/live`) — Business entities defined by the project schema. Each project has a slug (e.g., `crane-rental-management`) that appears in API URLs. Entities like `Person` bridge to tenant via a `personId` column.

**Actions layer** (`{engine}/actions/{project-slug}`) — Webhook/trigger runtime. `setVariables` configures runtime values (e.g., `apiKey`, `baseUrl`) that action triggers reference when calling external services.

**Data import** — HTTP POST to `{engine}/import` with bearer auth, `Content-Type: application/x-ndjson`, `Content-Encoding: gzip`. The body is a gzipped NDJSON file. Each line contains schema commands with a `project` field that may need remapping from production to local slug.

**Data export** — CLI: `contember data:export --output <path>`. Runs via the Docker-wrapped CLI (e.g., `_pkg_run contember data:export`). Output path must be within the Docker volume mount.

**Standard tokens:**
- `0000000000000000000000000000000000000000` (40 hex) — Root API token (`CONTEMBER_ROOT_TOKEN`)
- `1111111111111111111111111111111111111111` (40 hex) — Login token
- `2222222222222222222222222222222222222222` (40 hex) — Actions secret key / encryption key

**Database** — PostgreSQL with default credentials `contember`/`contember`/`contember`. Content data lives in schema `stage_live`. Direct SQL access via `docker compose exec -T postgres psql`.

## Workflow

### Step 1: Verify prerequisites

1. Read the existing `hatch.conf` (check `.hatch/hatch.conf` first, then `hatch.conf`)
2. Verify this is a Contember project:
   - `MIGRATE_TOOL="contember"` must be set
   - `contember-engine` must appear in `DOCKER_SERVICES`
   - If either is missing, stop and tell the user to run `hatch-init` first or that this supplement is only for Contember projects
3. Read `docker-compose.yml` (or `docker-compose.yaml`) and extract:
   - The **project slug** — look for `CONTEMBER_PROJECT_SLUG` in environment, or `--project-name` in command, or the project name in volume paths / env var values
   - Whether **minio** is present (for S3 storage)
   - Whether a **contember-cli** service exists
   - The engine service name (usually `contember-engine`)
4. Read `package.json` and find the `contember` script entry (typically `"contember": "docker compose run --rm contember-cli"`)
5. Store these discovered values — you will use them throughout:
   - `PROJECT_SLUG` (e.g., `crane-rental-management`)
   - `ENGINE_SERVICE` (e.g., `contember-engine`)
   - `HAS_MINIO` (boolean)
   - `PACKAGE_MANAGER` (from hatch.conf)

### Step 2: Read the Contember schema

The schema defines the project's data model. You need to discover entity names, relations, and roles to parameterize the generated hooks.

1. Find the schema directory:
   - Check `api/model/` first (most common)
   - If not found, check `api/schema/`, `api/src/model/`, or look at docker-compose.yml volume mounts for the contember engine/CLI service
2. Read all `.ts` files in the schema directory
3. Discover these project-specific values:

**Person entity** (the tenant bridge):
- Look for an entity with a `personId` column of type `Uuid` (e.g., `column('personId').type(Model.ColumnType.Uuid)` or `Schema.column('personId')`)
- This entity bridges Contember's tenant identity system to the content data model
- Note the exact entity name — it could be `Person`, `Employee`, `Member`, `Staff`, etc.

**User entity** (the application user):
- Look for an entity that has a many-to-one or one-to-one relation to the Person entity
- Typically has fields like `firstName`, `lastName`, `email`, or a `role` / `contentRoles` field
- Note the entity name and relevant field names

**Content roles**:
- Look for role definitions — `createRole()`, `acl.allow()`, or ACL configuration
- Common roles: `admin`, `editor`, `viewer`, `manager`, `developer`
- These determine what memberships to assign during user invitation

**Actions configuration**:
- Check for `api/actions/` directory or actions definitions in the schema
- If present, note the variable names used (typically `apiKey`, `baseUrl`)
- This determines whether the setup hook needs to configure Actions variables

**Email/phone columns** (for sanitization):
- You MUST read the actual entity definitions to find every column that contains email or phone data
- Search for column definitions containing `email`, `phone`, `mobilePhone`, `mobile`, `signer` etc.
- Map each entity name to its SQL table name: Contember converts `PascalCase` to `snake_case` (e.g., `CompanyContact` → `company_contact`, `ContractConfig` → `contract_config`)
- Map each field name similarly: `mobilePhone` → `mobile_phone`, `companySignerEmail` → `company_signer_email`
- Note the exact entity name, SQL table name, and SQL column name for each — do not guess
- These determine the SQL UPDATE statements in the `replace_emails` hook
- Present the complete list of `table.column` pairs to the user for confirmation before generating SQL

4. Present findings to the user and confirm before proceeding:
   - "I found entity `X` with `personId` field — is this the tenant bridge entity?"
   - "I found entity `Y` related to `X` — is this the application user entity?"
   - "I found roles: `a`, `b`, `c` — which should the root admin user get?"
   - "I found Actions config — should I set up webhook variables?"
   - "I found email columns on entities `A`, `B` — should these be sanitized?"

### Step 3: Verify/adjust hatch.conf for Contember specifics

Check each of these and suggest corrections if needed:

**DOCKER_ENV** — If minio is in DOCKER_SERVICES, the engine needs its S3 endpoint:
```
DOCKER_ENV="
  contember-engine:DEFAULT_S3_ENDPOINT=http://localhost:{PORT_minio}
"
```
If DOCKER_ENV already exists, append to it rather than replacing.

**Migration settings** — Verify these are correct:
```
MIGRATE_TOOL="contember"
MIGRATIONS_DIR="api/migrations"
MIGRATIONS_FILE_EXT="json"
```

**DB credentials** — Check docker-compose.yml for `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` and ensure hatch.conf matches:
```
DB_USER="contember"
DB_PASSWORD="contember"
DB_NAME="contember"
```

**POST_INSTALL_CMD** — Check `package.json` scripts for `client:generate`, `generate`, or `codegen`. If found:
```
POST_INSTALL_CMD="yarn client:generate"
```
(Use the actual package manager and script name.)

**HOOKS_FILE** — Set to the TypeScript hooks file:
```
HOOKS_FILE=".hatch/hatch.hooks.ts"
```

**SECRET_FILES** — Ensure `.hatch/.env.local` is listed (hooks may use it for email domain overrides):
```
SECRET_FILES="
  ...existing entries...
  .hatch/.env.local
"
```

**No duplication between SECRETS and PORT_TEMPLATES.** Each key should appear in exactly one block. Static values (tokens, project names, fixed URLs) go in `SECRETS`. Values with `{PORT_*}` placeholders go in `PORT_TEMPLATES`. If a value needs both a port and is secret, put it in `PORT_TEMPLATES` (the port injection mechanism handles it). Never put the same file:key in both blocks.

Present all proposed changes to the user and apply after confirmation.

### Step 4: Determine setup workflow

Ask the user about their setup needs and construct SETUP_STEPS. Ask these questions in order — each subsequent question only applies if the previous answer was yes:

1. **"Does this project import production/staging data for local development?"**
   - YES → steps will include `migrate:execute_until` + `data:import` + `migrate:execute` (split migration)
   - NO → steps will just have `migrate:execute` (skip to question 4)

2. **"Should imported emails and phone numbers be sanitized for dev safety?"** (only if importing data)
   - YES → add `custom:replace_emails` after `data:import`

3. **"Should imported users get local tenant accounts so they can log in?"** (only if importing data)
   - YES → add `custom:invite_imported_users` at the end
   - Follow-up: **"What role should users without explicit roles receive?"** (default: `admin`)

4. **"Should the setup create a root admin user linked to the Contember superuser?"**
   - YES → add `custom:project_setup`

5. **"Does the project use Actions (webhooks/triggers) that need variable configuration?"** (only if Actions config was found in Step 2)
   - YES → include Actions variable setup inside `project_setup`

Construct and present the full SETUP_STEPS. Example progressions:

- Minimal: `docker:up deps:install migrate:execute`
- With data: `docker:up deps:install migrate:execute_until data:import migrate:execute custom:project_setup`
- Full: `docker:up deps:install migrate:execute_until data:import custom:replace_emails migrate:execute custom:project_setup custom:invite_imported_users`

Also set the data command names (use project slug with hyphens→underscores as prefix):
```
DATA_IMPORT_CMD="project_import"
DATA_EXPORT_CMD="project_export"
```

Get explicit confirmation before proceeding.

### Step 5: Generate hooks files

Generate the `.hatch/` directory with TypeScript hooks. Create each file below, replacing `{{PLACEHOLDER}}` values with the project-specific values discovered in Steps 1-2.

**Important:** Before generating each file, read the project's existing code in the relevant areas (schema files, docker-compose.yml, package.json scripts) to validate that entity names, field names, and API patterns are correct. Never guess — verify.

#### File 1: `.hatch/hatch.hooks.ts`

The main hooks file. Must export every function referenced by `SETUP_STEPS` `custom:*` entries, `DATA_IMPORT_CMD`, and `DATA_EXPORT_CMD`.

```typescript
// {{PROJECT_NAME}} - Contember hatch hooks
// Generated by hatch-init-contember

import { importData, exportData } from "./lib/data.js";
import {
  getApiUrl,
  getDockerHost,
  createContentClient,
  createTenantClient,
  createActionsClient,
  runSql,
} from "./lib/contember.js";
import {
  getTenantPersonId,
  getTenantIdentityId,
  addProjectMember,
  inviteUser,
  lookupPersonByEmail,
  setActionsVariables,
} from "./lib/tenant.js";
import { generateEmail, assertUuid } from "./lib/strings.js";

const PROJECT_SLUG = "{{PROJECT_SLUG}}";
const TOKEN = "0000000000000000000000000000000000000000";
const ACTIONS_SECRET_KEY =
  "2222222222222222222222222222222222222222";

// ── Data Import/Export ──────────────────────────────────────────────

export async function project_import(exportFile: string) {
  await importData(exportFile, TOKEN, PROJECT_SLUG);
}

export async function project_export(exportPath: string) {
  await exportData(exportPath);
}

// ── Email Sanitization ──────────────────────────────────────────────
// Only include this function if the user confirmed email sanitization in Step 4

export async function replace_emails() {
  console.log("[info] Replacing emails and phone numbers...");

  // Read optional overrides from .hatch/.env.local
  let domain = "localhost";
  let phone = "+420000000000";
  try {
    const { readFileSync } = await import("fs");
    const envContent = readFileSync(".hatch/.env.local", "utf-8");
    for (const line of envContent.split("\n")) {
      if (line.startsWith("DEV_EMAIL_DOMAIN=")) domain = line.split("=")[1];
      if (line.startsWith("DEV_PHONE=")) phone = line.split("=")[1];
    }
  } catch {
    // .hatch/.env.local is optional
  }

  // {{SQL_SANITIZATION_BLOCK}}
  // Replace this block with project-specific SQL based on discovered entities.
  // Generate one runSql() call per table that has email or phone columns.
  // Example (replace table/column names with actual values from schema):
  //
  // await runSql(`
  //   UPDATE {{PERSON_TABLE}} SET
  //     email = CONCAT(LOWER(COALESCE(first_name, 'user')), '.', LOWER(COALESCE(last_name, id::text)), '@${domain}')
  //   WHERE email IS NOT NULL;
  // `);
  //
  // await runSql(`
  //   UPDATE {{PERSON_TABLE}} SET phone = '${phone}' WHERE phone IS NOT NULL;
  // `);

  console.log("[ok] Emails and phones replaced");
}

// ── Project Setup ───────────────────────────────────────────────────
// Only include this function if the user confirmed admin setup in Step 4

export async function project_setup() {
  const apiUrl = getApiUrl();
  const content = createContentClient(apiUrl, TOKEN, PROJECT_SLUG);
  const tenant = createTenantClient(apiUrl, TOKEN);

  console.log("=== {{PROJECT_NAME}}: Project-specific setup ===");

  // Step 1: Get tenant person ID
  console.log("[info] Getting tenant person ID...");
  const tenantPersonId = await getTenantPersonId(tenant);
  if (!tenantPersonId) {
    console.warn("[warn] Could not get tenant person ID");
    return;
  }
  console.log(`[info] Tenant person ID: ${tenantPersonId}`);

  // Step 2: Create {{PERSON_ENTITY}} record linked to tenant identity
  console.log("[info] Creating {{PERSON_ENTITY}} record...");
  const createRes = await content.query(
    `mutation($personId: String!) {
      create{{PERSON_ENTITY}}(data: { personId: $personId }) {
        ok node { id }
      }
    }`,
    { personId: tenantPersonId }
  );
  let personId = createRes?.data?.["create{{PERSON_ENTITY}}"]?.node?.id;

  // If create failed (already exists), look it up
  if (!personId) {
    const getRes = await content.query(
      `query($personId: String!) {
        get{{PERSON_ENTITY}}(by: { personId: $personId }) { id }
      }`,
      { personId: tenantPersonId }
    );
    personId = getRes?.data?.["get{{PERSON_ENTITY}}"]?.id;
  }

  if (personId) {
    console.log(`[info] {{PERSON_ENTITY}} ID: ${personId}`);

    // Step 3: Create {{USER_ENTITY}} record
    console.log("[info] Creating {{USER_ENTITY}} record...");
    await content.query(
      `mutation($personId: ID!) {
        create{{USER_ENTITY}}(data: {
          {{PERSON_RELATION}}: { connect: { id: $personId } }
          firstName: "Contember"
          lastName: "Admin"
        }) { ok }
      }`,
      { personId }
    );
    console.log("[ok] Admin user created");
  } else {
    console.warn("[warn] Could not create/find {{PERSON_ENTITY}} record");
  }

  // Step 4: Add project membership roles to root identity
  console.log("[info] Adding project membership roles...");
  const identityId = await getTenantIdentityId(tenant);
  if (identityId) {
    const added = await addProjectMember(tenant, PROJECT_SLUG, identityId, [
      {{ADMIN_ROLES}},
    ].map((role) => ({ role, variables: [] })));
    if (added) {
      console.log("[ok] Project membership roles added");
    } else {
      console.warn(
        "[warn] Could not add project membership roles (may already exist)",
      );
    }
  } else {
    console.warn(
      "[warn] Could not get identity ID, skipping membership setup",
    );
  }

  // {{ACTIONS_SETUP_BLOCK}}

  console.log("[ok] {{PROJECT_NAME}} setup complete");
}

// ── User Invitation ─────────────────────────────────────────────────
// Only include this function if the user confirmed user invitation in Step 4

export async function invite_imported_users() {
  const apiUrl = getApiUrl();
  const content = createContentClient(apiUrl, TOKEN, PROJECT_SLUG);
  const tenant = createTenantClient(apiUrl, TOKEN);

  console.log("=== Inviting imported users ===");

  // Get root tenant person ID so we can skip the admin user
  // (project_setup already linked this Person correctly)
  const rootTenantPersonId = await getTenantPersonId(tenant);

  // Query all {{USER_ENTITY}} records
  const result = await content.query(`
    query {
      list{{USER_ENTITY}}(limit: 1000) {
        id
        firstName
        lastName
        {{PERSON_RELATION}} { id personId }
        {{ROLES_FIELD_QUERY}}
      }
    }
  `);

  const users = result?.data?.["list{{USER_ENTITY}}"] ?? [];
  if (users.length === 0) {
    console.warn("[warn] No users found to invite");
    return;
  }
  console.log(`[info] Found ${users.length} users to invite`);

  // Process in batches: invite via tenant API, collect Person links
  const pendingLinks: Array<{
    personContentId: string;
    tenantPersonId: string;
  }> = [];
  const BATCH_SIZE = 10;

  for (let i = 0; i < users.length; i += BATCH_SIZE) {
    const batch = users.slice(i, i + BATCH_SIZE);
    const batchEnd = Math.min(i + BATCH_SIZE, users.length);
    console.log(
      `Batch ${Math.floor(i / BATCH_SIZE) + 1}: inviting users ${i + 1}-${batchEnd}...`,
    );

    for (const user of batch) {
      // Skip the admin user created by project_setup — its Person
      // is already linked to the root tenant person
      if (
        rootTenantPersonId &&
        user.{{PERSON_RELATION}}?.personId === rootTenantPersonId
      ) {
        console.log(
          `  Skipping ${user.firstName} ${user.lastName} (already linked to root tenant person)`,
        );
        continue;
      }

      const email = generateEmail(
        user.firstName ?? "",
        user.lastName ?? "",
        user.id,
      );

      // Build memberships from content roles
      const memberships = {{MEMBERSHIP_BUILDER}};

      // If no roles found, use default membership
      if (memberships.length === 0) {
        memberships.push({ role: "{{DEFAULT_INVITE_ROLE}}", variables: [] });
      }

      const inviteResult = await inviteUser(
        tenant,
        email,
        PROJECT_SLUG,
        memberships,
      );
      let tenantPersonId = inviteResult.personId;

      if (!tenantPersonId && inviteResult.alreadyMember) {
        const found = await lookupPersonByEmail(tenant, email);
        tenantPersonId = found?.id;
      }

      if (!tenantPersonId) {
        console.warn(`  Could not invite or look up ${email}`);
        continue;
      }

      const personContentId = user.{{PERSON_RELATION}}?.id;
      if (personContentId) {
        pendingLinks.push({ personContentId, tenantPersonId });
      } else {
        console.warn(`  Invited but no Person record to link: ${email}`);
      }
    }

    // Flush Person.personId updates for this batch via batched SQL
    // Uses a NOT EXISTS guard to skip if the tenant person ID is already claimed
    if (pendingLinks.length > 0) {
      const values = pendingLinks
        .filter((l) => {
          try {
            assertUuid(l.personContentId, "personContentId");
            assertUuid(l.tenantPersonId, "tenantPersonId");
            return true;
          } catch {
            console.warn(
              `  Skipping link with invalid UUID: ${l.personContentId} / ${l.tenantPersonId}`,
            );
            return false;
          }
        })
        .map(
          (l) =>
            `('${l.personContentId}'::uuid, '${l.tenantPersonId}'::uuid)`,
        )
        .join(", ");

      if (values) {
        await runSql(
          `UPDATE {{PERSON_TABLE}} SET person_id = v.new_pid ` +
            `FROM (VALUES ${values}) AS v(content_id, new_pid) ` +
            `WHERE {{PERSON_TABLE}}.id = v.content_id ` +
            `AND NOT EXISTS (SELECT 1 FROM {{PERSON_TABLE}} other WHERE other.person_id = v.new_pid AND other.id != {{PERSON_TABLE}}.id)`,
        );
        console.log(`  Linked ${pendingLinks.length} Person records`);
      }
      pendingLinks.length = 0;
    }
  }

  console.log(`[ok] User invitation complete (${users.length} users processed)`);
}
```

**Placeholder reference for `.hatch/hatch.hooks.ts`:**

| Placeholder | Source | Example |
|---|---|---|
| `{{PROJECT_NAME}}` | hatch.conf `PROJECT_NAME` | `crane-rental` |
| `{{PROJECT_SLUG}}` | docker-compose.yml | `crane-rental-management` |
| `{{PERSON_ENTITY}}` | Schema entity with `personId` | `Person` |
| `{{USER_ENTITY}}` | Schema entity related to Person | `User` |
| `{{PERSON_RELATION}}` | Field name on User → Person | `person` |
| `{{PERSON_TABLE}}` | SQL table name (snake_case of entity) | `person` |
| `{{ADMIN_ROLES}}` | Roles for root admin (from Step 2) | `"admin", "developer"` |
| `{{ROLES_FIELD_QUERY}}` | GraphQL field for user roles | `contentRoles` |
| `{{MEMBERSHIP_BUILDER}}` | Code to build membership array from user | See note below |
| `{{DEFAULT_INVITE_ROLE}}` | Fallback role for users without explicit roles | `admin` |
| `{{SQL_SANITIZATION_BLOCK}}` | SQL UPDATEs for email/phone columns | See note below |
| `{{ACTIONS_SETUP_BLOCK}}` | Actions variable configuration | See note below |

**Note on `{{MEMBERSHIP_BUILDER}}`:** This depends on how the project stores roles. Common patterns:
- Single role field: `[{ role: user.role, variables: [] }]`
- Array of roles: `(user.contentRoles ?? []).map((r: string) => ({ role: r, variables: [] }))`
- Fixed role: `[{ role: "viewer", variables: [] }]`

**Note on `{{SQL_SANITIZATION_BLOCK}}`:** Generate one SQL UPDATE per entity that has email or phone columns. Use `runSql()` for each. The SQL must:
- Replace emails with deterministic values (use `CONCAT()` with name columns or `id`)
- Replace phones with the dev placeholder
- Only update non-null values
- Use the `stage_live` schema (default for `runSql()`)

**Note on `{{ACTIONS_SETUP_BLOCK}}`:** If the project uses Actions, include:
```typescript
  // Step 5: Set system variables
  console.log("[info] Setting system variables...");
  const workerPort = process.env.HATCH_PORT_worker;
  if (!workerPort) {
    console.warn("[warn] HATCH_PORT_worker is not set, skipping variable setup");
  } else {
    const actions = createActionsClient(apiUrl, TOKEN, PROJECT_SLUG);
    const ok = await setActionsVariables(actions, [
      { name: "apiKey", value: ACTIONS_SECRET_KEY },
      { name: "baseUrl", value: `http://${getDockerHost()}:${workerPort}` },
    ]);
    if (ok) {
      console.log("[ok] Variables set successfully");
    } else {
      console.warn("[warn] Failed to set variables");
    }
  }
```
If Actions are not used, omit this block entirely.

**Only include functions that the user confirmed in Step 4.** If they don't need email sanitization, omit `replace_emails`. If they don't need user invitation, omit `invite_imported_users`. Remove the corresponding imports too.

#### File 2: `.hatch/lib/contember.ts`

API client factories and SQL runner. This file is project-agnostic — it works for any Contember project.

```typescript
// Contember API client factories for hatch hooks

export function getApiUrl(): string {
  const port = process.env.HATCH_PORT_contember_engine;
  if (!port) throw new Error("HATCH_PORT_contember_engine not set");
  return `http://localhost:${port}`;
}

export function getDockerHost(): string {
  return process.platform === "darwin"
    ? "host.docker.internal"
    : "172.17.0.1";
}

export interface GqlClient {
  query(
    query: string,
    variables?: Record<string, unknown>
  ): Promise<any>;
}

function createGqlClient(url: string, token: string): GqlClient {
  return {
    async query(
      query: string,
      variables?: Record<string, unknown>
    ): Promise<any> {
      const res = await fetch(url, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ query, variables }),
      });
      if (!res.ok) {
        throw new Error(`GraphQL request failed: ${res.status} ${res.statusText}`);
      }
      return res.json();
    },
  };
}

export function createContentClient(
  apiUrl: string,
  token: string,
  projectSlug: string
): GqlClient {
  return createGqlClient(`${apiUrl}/content/${projectSlug}/live`, token);
}

export function createTenantClient(
  apiUrl: string,
  token: string
): GqlClient {
  return createGqlClient(`${apiUrl}/tenant`, token);
}

export function createActionsClient(
  apiUrl: string,
  token: string,
  projectSlug: string
): GqlClient {
  return createGqlClient(`${apiUrl}/actions/${projectSlug}`, token);
}

export async function runSql(
  sql: string,
  schema = "stage_live"
): Promise<string> {
  const { execSync } = await import("child_process");
  const fullSql = `SET search_path TO "${schema}"; ${sql}`;
  return execSync(
    `docker compose exec -T postgres psql -U contember -d contember -c ${JSON.stringify(fullSql)}`,
    { encoding: "utf-8" }
  );
}
```

#### File 3: `.hatch/lib/data.ts`

Streaming data import and export. The import uses HTTP POST to avoid Docker volume mount path issues. The export uses the CLI because hatch creates the output path within the project directory.

```typescript
// Streaming NDJSON data import/export for Contember

import { createReadStream } from "node:fs";
import { createGunzip, createGzip } from "node:zlib";
import { Readable, Transform } from "node:stream";
import { getApiUrl } from "./contember.js";

/**
 * Streaming import that remaps project names in the NDJSON commands.
 *
 * Export files from different environments (prod/dev) use different project slugs
 * in `importSystemSchemaBegin` and `importContentSchemaBegin` commands. This function
 * streams the file line-by-line, rewrites those commands to use the local project slug,
 * and sends the result to the Contember import endpoint.
 *
 * Uses Node.js Transform streams so it never holds the full file in memory.
 */
export async function importData(
  exportFile: string,
  token: string,
  projectSlug: string,
): Promise<void> {
  const apiUrl = getApiUrl();

  console.log(`[info] Importing to ${apiUrl}/import`);
  console.log(`[info] Target project: ${projectSlug}`);

  let rowCount = 0;
  const remappedProjects = new Set<string>();

  // Build the streaming pipeline: file → gunzip → split lines → remap → gzip
  const fileStream = createReadStream(exportFile);
  const gunzip = createGunzip();
  const gzip = createGzip();

  // Transform that splits on newlines and remaps project names in schema-begin commands
  let buffer = "";
  const lineRemapper = new Transform({
    transform(chunk: Buffer, _encoding, callback) {
      buffer += chunk.toString("utf-8");
      const lines = buffer.split("\n");
      // Keep last partial line in buffer
      buffer = lines.pop()!;

      for (const line of lines) {
        if (line.length === 0) continue;
        const remapped = remapLine(line, projectSlug, remappedProjects);
        this.push(remapped + "\n");
        rowCount++;
        if (rowCount % 10_000 === 0) {
          console.log(`  ${rowCount.toLocaleString()} rows processed...`);
        }
      }
      callback();
    },
    flush(callback) {
      if (buffer.length > 0) {
        const remapped = remapLine(buffer, projectSlug, remappedProjects);
        this.push(remapped + "\n");
        rowCount++;
      }
      callback();
    },
  });

  // Pipe: file → gunzip → remap lines → gzip
  const pipeline = fileStream.pipe(gunzip).pipe(lineRemapper).pipe(gzip);

  // Convert Node.js stream to web ReadableStream for fetch
  const webStream = Readable.toWeb(pipeline);

  const response = await fetch(`${apiUrl}/import`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/x-ndjson",
      "Content-Encoding": "gzip",
    },
    body: webStream,
    // @ts-expect-error -- Node.js fetch requires duplex for streaming request bodies
    duplex: "half",
  });

  if (!response.ok) {
    const text = await response.text();
    throw new Error(`Import failed (${response.status}): ${text}`);
  }

  console.log(`[ok] Import complete: ${rowCount.toLocaleString()} rows`);
  if (remappedProjects.size > 0) {
    console.log(
      `[info] Remapped projects: ${[...remappedProjects].join(", ")} → ${projectSlug}`,
    );
  }
}

/**
 * NDJSON lines use a tuple format: ["commandName", { ...payload }]
 * Schema-begin commands have a `project` field in the payload that may
 * reference the source environment's slug and needs remapping to local.
 */
const SCHEMA_BEGIN_COMMANDS = new Set([
  "importSystemSchemaBegin",
  "importContentSchemaBegin",
]);

function remapLine(
  line: string,
  targetProject: string,
  remapped: Set<string>,
): string {
  // Quick check: only parse JSON if the line might contain a schema-begin command
  if (!line.includes("SchemaBegin")) return line;

  try {
    const command = JSON.parse(line) as [string, Record<string, unknown>];
    if (!Array.isArray(command) || command.length < 2) return line;

    const [commandName, payload] = command;
    if (!SCHEMA_BEGIN_COMMANDS.has(commandName)) return line;

    const sourceProject =
      typeof payload.project === "string" ? payload.project : undefined;
    if (sourceProject && sourceProject !== targetProject) {
      remapped.add(sourceProject);
      return JSON.stringify([
        commandName,
        { ...payload, project: targetProject },
      ]);
    }
  } catch {
    // Not valid JSON or unexpected shape — pass through unchanged
  }

  return line;
}

export async function exportData(exportPath: string): Promise<void> {
  const { execSync } = await import("child_process");
  execSync(
    `{{PACKAGE_MANAGER}} contember data:export --output ${JSON.stringify(exportPath)}`,
    { stdio: "inherit" },
  );
}
```

**Important:** The `importData` function always streams and automatically remaps any project slug that differs from the local `projectSlug`. It never buffers the full file in memory — it uses a Node.js Transform stream pipeline (`file → gunzip → line remapper → gzip → fetch`). The NDJSON format uses JSON array tuples: `["commandName", { project: "slug", ... }]` — the remapper parses this tuple format, not plain objects.

#### File 4: `.hatch/lib/tenant.ts`

Tenant API GraphQL operations. This file is project-agnostic.

```typescript
// Tenant API operations for Contember hatch hooks

import type { GqlClient } from "./contember.js";

export async function getTenantPersonId(
  tenant: GqlClient,
): Promise<string | undefined> {
  const res = await tenant.query("query { me { person { id } } }");
  return res?.data?.me?.person?.id;
}

export async function getTenantIdentityId(
  tenant: GqlClient,
): Promise<string | undefined> {
  const res = await tenant.query("query { me { id } }");
  return res?.data?.me?.id;
}

export async function addProjectMember(
  tenant: GqlClient,
  projectSlug: string,
  identityId: string,
  memberships: {
    role: string;
    variables: { name: string; values: string[] }[];
  }[],
): Promise<boolean> {
  const res = await tenant.query(
    `mutation($projectSlug: String!, $identityId: String!, $memberships: [MembershipInput!]!) {
      addProjectMember(
        projectSlug: $projectSlug
        identityId: $identityId
        memberships: $memberships
      ) {
        ok
        error { code }
      }
    }`,
    { projectSlug, identityId, memberships },
  );
  return res?.data?.addProjectMember?.ok ?? false;
}

export async function inviteUser(
  tenant: GqlClient,
  email: string,
  projectSlug: string,
  memberships: {
    role: string;
    variables: { name: string; values: string[] }[];
  }[],
): Promise<{ personId?: string; alreadyMember?: boolean }> {
  const res = await tenant.query(
    `mutation($email: String!, $projectSlug: String!, $memberships: [MembershipInput!]!) {
      unmanagedInvite(
        email: $email
        projectSlug: $projectSlug
        memberships: $memberships
        options: { password: "contember" }
      ) {
        ok
        error { code }
        result { person { id } }
      }
    }`,
    { email, projectSlug, memberships },
  );

  const invite = res?.data?.unmanagedInvite;
  if (invite?.ok && invite.result?.person?.id) {
    return { personId: invite.result.person.id };
  }

  if (invite?.error?.code === "ALREADY_MEMBER") {
    return { alreadyMember: true };
  }

  console.warn(
    `  Failed to invite ${email} (${invite?.error?.code ?? "UNKNOWN"})`,
  );
  return {};
}

export async function lookupPersonByEmail(
  tenant: GqlClient,
  email: string,
): Promise<{ id: string; identityId: string } | null> {
  const res = await tenant.query(
    `query($email: String!) {
      personByEmail(email: $email) {
        id
        identity { id }
      }
    }`,
    { email },
  );
  const person = res?.data?.personByEmail;
  if (!person) return null;
  return { id: person.id, identityId: person.identity.id };
}

export async function setActionsVariables(
  actions: GqlClient,
  variables: { name: string; value: string }[],
): Promise<boolean> {
  const res = await actions.query(
    `mutation($variables: [VariableInput!]!) {
      setVariables(args: { variables: $variables }) { ok }
    }`,
    { variables },
  );
  return res?.data?.setVariables?.ok ?? false;
}
```

#### File 5: `.hatch/lib/strings.ts`

Email normalization utilities. This file is project-agnostic.

```typescript
// String utilities for Contember hatch hooks

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Validate a string is a well-formed UUID before interpolating into SQL.
 * Throws if the value doesn't match the UUID pattern.
 */
export function assertUuid(value: string, label: string): string {
  if (!UUID_RE.test(value))
    throw new Error(`Invalid UUID for ${label}: ${value}`);
  return value;
}

/**
 * Normalize a name to an email-safe ASCII string.
 * Handles Unicode characters (accents, diacritics) by decomposing them.
 */
export function toEmailPart(str: string): string {
  return str
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "") // Strip combining marks
    .toLowerCase()
    .replace(/\s+/g, "-")
    .replace(/[^a-z0-9-]/g, "")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");
}

/**
 * Generate a deterministic dev email from name parts.
 * Falls back to ID-based email if no name is available.
 */
export function generateEmail(
  firstName: string,
  lastName: string,
  id?: string,
  domain = "localhost",
): string {
  const first = firstName ? toEmailPart(firstName) : "";
  const last = lastName ? toEmailPart(lastName) : "";

  if (first && last) return `${first}.${last}@${domain}`;
  if (first) return `${first}@${domain}`;
  if (last) return `${last}@${domain}`;
  if (id) return `user-${id.slice(0, 8)}@${domain}`;
  return `user-unknown@${domain}`;
}
```

### Step 6: Update hatch.conf

Apply the following changes to `hatch.conf` using the Edit tool:

1. Set `DATA_IMPORT_CMD` and `DATA_EXPORT_CMD` (only if data import was confirmed)
2. Set `HOOKS_FILE=".hatch/hatch.hooks.ts"`
3. Update `SETUP_STEPS` to the confirmed value from Step 4
4. Add/update `DOCKER_ENV` entries identified in Step 3
5. Add `.hatch/.env.local` to `SECRET_FILES` if not already present

## Important Rules

1. **Schema first** — Always read the Contember schema before generating hooks. Entity names, field names, and role names vary by project. Never assume they are `Person`/`User`/`admin`.
2. **Never hardcode ports** — Always use `process.env.HATCH_PORT_*` (hyphens and dots become underscores in env var names).
3. **Never hardcode project slugs** — Use the `PROJECT_SLUG` constant at the top of hooks, discovered from docker-compose.yml.
4. **Import uses HTTP, export uses CLI** — The import file is an absolute host path outside Docker's volume mount, so use `fetch()` to POST directly. Export writes within the project dir (accessible to Docker), so the CLI works.
5. **SQL for bulk operations** — Email replacement and person ID linking use `runSql()` (via `docker compose exec -T postgres psql`) because GraphQL mutations would be too slow for thousands of records.
6. **`runSql` uses `stage_live` schema** — Contember stores content data in the `stage_live` PostgreSQL schema. Table names are `snake_case` versions of entity names.
7. **`unmanagedInvite` may return `ALREADY_MEMBER`** — This is expected on re-runs. Handle it gracefully by looking up the existing person ID.
8. **Default invite password is `contember`** — All locally invited users get this password.
9. **Only generate functions the user confirmed** — If they said no to email sanitization, don't generate `replace_emails`. Remove unused imports too.
10. **TypeScript imports use `.js` extension** — ESM resolution requires `.js` even for `.ts` source files (e.g., `import { ... } from "./lib/contember.js"`).
11. **All exports must be `export async function` with `snake_case` names** — This is how the hatch TypeScript hook runner discovers and calls them.
12. **Setup hooks should be resilient** — These run during workspace provisioning. Partial success is better than aborting on the first failure. Use `console.warn()` and continue rather than throwing errors, except for truly fatal conditions (e.g., can't connect to the API at all). Functions in `lib/tenant.ts` should return `undefined`/`null`/`false` on non-fatal errors; the hooks file should check and skip gracefully.
13. **Always validate UUIDs before SQL interpolation** — Use `assertUuid()` from `lib/strings.ts` before interpolating any ID into a raw SQL string. This prevents SQL injection from malformed data.
14. **Batch SQL updates for Person linking** — In `invite_imported_users`, collect pending Person→tenant links during the batch, then flush with a single `UPDATE ... FROM (VALUES ...)` statement. Include a `NOT EXISTS` guard to avoid overwriting if the tenant person ID is already claimed by another Person record.
15. **No duplication between SECRETS and PORT_TEMPLATES** — Each `file:KEY` pair must appear in exactly one block. Static values go in `SECRETS`, port-templated values in `PORT_TEMPLATES`.
16. **The NDJSON import format uses JSON array tuples** — Each line is `["commandName", { ...payload }]`. The `project` field is inside the payload object at index 1, not at the top level. The remapper must parse this tuple format correctly.
