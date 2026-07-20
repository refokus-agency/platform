// Records a GitHub Deployment so the repo's Environments/Deployments
// view reflects real deploys instead of stale records from a
// disconnected Vercel Git integration. Requires the caller to grant
// `deployments: write`; if it hasn't, this degrades to a warning
// rather than failing the (already successful) deploy.
module.exports = async ({ github, context, core }) => {
  const environment = process.env.ENVIRONMENT;
  try {
    const { data: deployment } = await github.rest.repos.createDeployment({
      owner: context.repo.owner,
      repo: context.repo.repo,
      ref: process.env.REF,
      environment,
      description: `Vercel ${environment} deploy`,
      auto_merge: false,
      required_contexts: [],
      production_environment: environment === 'production',
    });
    if (!deployment || !deployment.id) {
      core.warning(`Skipped recording: createDeployment returned no id (${JSON.stringify(deployment)}).`);
      return;
    }
    await github.rest.repos.createDeploymentStatus({
      owner: context.repo.owner,
      repo: context.repo.repo,
      deployment_id: deployment.id,
      state: 'success',
      environment_url: process.env.DEPLOY_URL,
      log_url: `${context.serverUrl}/${context.repo.owner}/${context.repo.repo}/actions/runs/${context.runId}`,
      auto_inactive: true,
    });
    core.info(`Recorded ${environment} deployment #${deployment.id}.`);
  } catch (error) {
    core.warning(`Could not record GitHub deployment (grant \`deployments: write\` to enable): ${error.message}`);
  }
};
