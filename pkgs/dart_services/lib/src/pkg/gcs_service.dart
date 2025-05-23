import 'package:googleapis/storage/v1.dart';
import 'package:googleapis_auth/auth_io.dart';

class GCSService {
  late StorageApi _storageApi;

  GCSService() {
    init();
  }

  Future<void> init() async {
    // Use the default application credentials
    final client = await clientViaApplicationDefaultCredentials(
      scopes: [StorageApi.devstorageFullControlScope],
    );
    _storageApi = StorageApi(client);
  }

  Future<void> upload(String bucketName, Media media, String key) async {
    await _storageApi.objects.insert(
      Object()..name = key,
      bucketName,
      uploadMedia: media,
    );
  }
}