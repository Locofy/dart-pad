# Flutter Cloud Build community image

To create and upload new Docker images to Google Container Registry, run: 

```bash
gcloud builds submit . \
--config=docker/flutter-base/cloudbuild.yaml  
```

Original source: [cloud-builders-community][].

[cloud-builders-community]: https://github.com/GoogleCloudPlatform/cloud-builders-community/blob/master/flutter/Dockerfile
