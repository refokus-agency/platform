// GitHub Deployment lifecycle for deploy.yml, all environments.
//
//   start()  — runs before the Vercel build: creates the deployment and
//              posts `in_progress`, exposing its id as `deployment-id`.
//   finish() — runs last, under `always()`: posts `success` (with the
//              Vercel URL) or `failure`.
//
// Preview deployments are keyed on the PR head SHA in a transient
// environment, so `GET /deployments?environment=preview&sha=<head>` finds
// the preview for a commit.
//
// Both need the caller to grant `deployments: write`. What happens without
// it is decided in onApiError() below.
const runUrl = (context) =>
  `${context.serverUrl}/${context.repo.owner}/${context.repo.repo}/actions/runs/${context.runId}`;

// 403/404 is what a token without `deployments: write` gets. Only then does
// the error message point at the permission.
const isPermissionError = (error) => error.status === 403 || error.status === 404;

// Runs one API call, retrying it once unless the error is a permission error,
// which a retry cannot fix. Any other failure (5xx, rate limit, 422, ...) gets
// one more try, so a transient error does not fail a preview that is fine.
async function withRetry(call, core) {
  try {
    return await call();
  } catch (error) {
    if (isPermissionError(error)) throw error;
    core.info(`GitHub API call failed (${error.message}); retrying once.`);
    return await call();
  }
}

// The one place the required/opt-in rule lives. Preview: required — the code
// review looks the preview up by deployment, so a missing record is a
// failed deploy. Stage/production: opt-in, as in v1 — warn and keep going.
function onApiError(environment, message, core, error) {
  const permission = Boolean(error) && isPermissionError(error);
  if (environment === 'preview') {
    core.setFailed(
      permission
        ? `${message}. Preview deploys must be recorded as GitHub deployments: ` +
            'grant `deployments: write` in the calling workflow\'s `permissions:` block.'
        : `${message}. Preview deploys must be recorded as GitHub deployments.`,
    );
    return;
  }
  core.warning(
    permission ? `${message}. Grant \`deployments: write\` to record ${environment} deploys.` : message,
  );
}

module.exports.start = async ({ github, context, core }) => {
  const environment = process.env.ENVIRONMENT;
  const isPreview = environment === 'preview';
  try {
    const { data: deployment } = await withRetry(
      () =>
        github.rest.repos.createDeployment({
          owner: context.repo.owner,
          repo: context.repo.repo,
          ref: isPreview ? process.env.HEAD_SHA : process.env.REF_NAME,
          environment,
          description: `Vercel ${environment} deploy`,
          auto_merge: false,
          required_contexts: [],
          transient_environment: isPreview,
          production_environment: environment === 'production',
        }),
      core,
    );
    // A response without an id (e.g. a 202 merge message) created nothing:
    // output no id, so the finish step is skipped instead of posting to NaN.
    if (!deployment || !deployment.id) {
      onApiError(
        environment,
        'Could not start the GitHub deployment: GitHub returned no deployment id',
        core,
      );
      return;
    }
    // Expose the id before anything else can fail: once the deployment exists,
    // the finish step must close it, even if the in_progress post below throws
    // or the run is cancelled right here.
    core.setOutput('deployment-id', String(deployment.id));
    await withRetry(
      () =>
        github.rest.repos.createDeploymentStatus({
          owner: context.repo.owner,
          repo: context.repo.repo,
          deployment_id: deployment.id,
          state: 'in_progress',
          log_url: runUrl(context),
          // GitHub defaults this to true. A deploy that is still running (and
          // may fail) must not retire the last good deployment.
          auto_inactive: false,
        }),
      core,
    );
    core.info(`Started ${environment} deployment #${deployment.id}.`);
  } catch (error) {
    onApiError(environment, `Could not start the GitHub deployment: ${error.message}`, core, error);
  }
};

module.exports.finish = async ({ github, context, core }) => {
  const environment = process.env.ENVIRONMENT;
  const deploymentId = Number(process.env.DEPLOYMENT_ID);
  // Success means Vercel actually serves the deploy: `vercel deploy` succeeded
  // with a URL and, for stage, the stage alias points at it. Not `job.status`:
  // a failed PR comment must not record a live preview as failed. Anything
  // else (a failed, skipped or cancelled deploy) is a failure: no URL, and the
  // last good deployment stays active.
  const succeeded =
    process.env.DEPLOY_OUTCOME === 'success' &&
    Boolean(process.env.DEPLOY_URL) &&
    (environment !== 'stage' || process.env.ALIAS_OUTCOME === 'success');
  const status = succeeded
    ? {
        state: 'success',
        environment_url: process.env.DEPLOY_URL,
        // Every PR's preview shares the `preview` environment: a new preview
        // must not retire the others. Stage/production replace the previous one.
        auto_inactive: environment !== 'preview',
      }
    : { state: 'failure', auto_inactive: false };
  try {
    await withRetry(
      () =>
        github.rest.repos.createDeploymentStatus({
          owner: context.repo.owner,
          repo: context.repo.repo,
          deployment_id: deploymentId,
          log_url: runUrl(context),
          ...status,
        }),
      core,
    );
    core.info(`Finished ${environment} deployment #${deploymentId}: ${status.state}.`);
  } catch (error) {
    onApiError(
      environment,
      `Could not post the final status of GitHub deployment #${deploymentId}: ${error.message}`,
      core,
      error,
    );
  }
};

module.exports.onApiError = onApiError;
