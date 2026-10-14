# Semi-secret homelab data — PII (public domain names and the upstream mail
# host) that must not appear in the public GitHub mirror of this repo.
#
# This data used to live in a separate private `homelab-private` flake. It is
# now in-tree and is scrubbed by .forgejo/workflows/mirror-to-github.yml, which
# rewrites the values below to example.com placeholders on the mirror. Keep the
# replacement list in that workflow in sync with the fields here.
{
  domain = {
    prod = "example.com";
    stage = "stage.example.com";
  };
  mailhost = "mail.example.com";
}
