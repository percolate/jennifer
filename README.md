# jennifer

A node.js daemon that syncs Github pull requests with Jenkins jobs, by
[jamesob](https://github.com/jamesob)
at Percolate.  Began as a fork of [this](https://gist.github.com/1911084).

For each open pull request in Github, a Jenkins job is created and builds
whenever the associated branch is pushed to. Upon each build, success or
failure is posted back to the PR's status.

![ooooh. stoplights.](https://github.com/percolate/jennifer/raw/master/public/assets/images/scshot.jpeg "Oooh. PR stoplights.")

## Features

- Jenkins job per PR, sync'd on the minute
- Github commit status API integration (thanks [@mattheath](https://github.com/mattheath)!)

## Github setup

Configure Github's post-receive hooks to fire to URL
`http://some-login:some-password@your-jenkins-url/github-webhook/`.

You haven't done anything with that login combination yet, so don't worry.
Ultimately, you will use that information to register a Jenkins user that
Github can use.

Create an OAuth authorization with a user who has access to the repo being
PR'd to and remember it for later. It will be used in a Jennifer environment
variable.

## Jenkins setup

2. Enable the `git` and `github` plugins.
1. For authentication, use *Jenkins' own user database*. Create a user with
  the credentials you used in the Github post-receive hook above.
3. Create yet another user to be used by Jennifer with full privileges.
3. Create a Job which will serve as a template for each PR-specific job. Name
  it anything so long as it doesn't begin with `pr_\d+_`; that will be a
  naming convention reserved for PR-specific jobs. I called this
  `pull_request_job_template`.
  * Configure it with the right Github project, etc.
  * For *Source Code Management*, select *Git* and specify the repo URL, etc.,
    but for *Branch specifier*, put `${pr_branch}`. This is a sort-of-horrible
    hack wherein that special identifier is substituted out for the actual
    branch associated with a given PR.
  * Under *Build Triggers*, select *Trigger builds remotely...*. Pick an
    authentication token and remember it for later.
  * Again under `Build Triggers`, select *Build when a change is pushed to
    GitHub*.
  * Under *Build*, run your tests, etc., but within the same script as running
    your tests, establish an environment variable (maybe called `SUCCESS`?)
    that is set to `success` if your build succeeded and something else
    otherwise. Have this run after the build is complete:

    ```sh
    curl "http://your-jennifer-url:3000/jenkins/post_build?\
        user=gh_user_who_owns_the_repo\
        &repo=gh_repo\
        &sha=$GIT_COMMIT\
        &status=$SUCCESS\
        &job=$JOB_NAME\
        &build=$BUILD_NUMBER"
    ```

    There might be some spacing issues there, but you get the picture.

## Jennifer setup

0. Clone this and install dependencies with `npm install`.
1. Establish all environment variables as dictated by `env.coffee`.
  These should be similar to the some of the values used above; hopefully after
  faring the above instructions, you will have an intuition for the naming.
2. Run it with `node server.js`. It will log out to `jennifer.log`.

After that, you should have a few new jobs in Jenkins. They should (not by
coincidence) match the pull requests you currently have open. Status will be
updated as pushes happen. Comments will be made to the PR discussion. Hooray.
