import 'dart:async';
import 'dart:io';

import 'package:beaver_core/beaver_core.dart' as beaver_core;
import 'package:path/path.dart' as path;
import 'package:pub_wrapper/pub_wrapper.dart';
import 'package:yaml/yaml.dart';

import './base.dart';
import './utils/reflection.dart';

const String taskInstancesKey = 'taskInstances';

class JobDescription {
  final YamlList jobs;
  final Uri descriptionFile;
  final Uri customJobFile;
  final Uri packageDescriptionFile;

  JobDescription(this.jobs, this.descriptionFile, this.customJobFile,
      this.packageDescriptionFile);

  @override
  String toString() {
    final buffer = new StringBuffer();
    buffer
      ..writeln('JobDescription: ')
      ..writeln('jobs: ${jobs}')
      ..writeln('descriptionFile: ${descriptionFile.toFilePath()}')
      ..writeln('customJobFile: ${customJobFile.toFilePath()}')
      ..writeln('packageDescriptionFile: ${packageDescriptionFile}');
    return buffer.toString();
  }
}

class JobDescriptionLoader {
  final Context _context;
  final TriggerConfig _triggerConfig;

  JobDescriptionLoader(this._context, this._triggerConfig);

  Future<JobDescription> load() async {
    _context.logger.fine('JobDescriptionLoader started.');
    // FIXME: If triggerConfig has a valid token, use it to get JobDescription.
    final httpClient = new HttpClient();

    final destDir = await _getDestinationDirectory(_triggerConfig.id);
    final jobDescriptionUrl = _getJobDescriptionUrl(_triggerConfig.sourceUrl);
    final jobDescriptionFile =
        await _downloadFile(httpClient, jobDescriptionUrl, to: destDir);
    final jobs =
        loadYaml(await jobDescriptionFile.readAsString())[taskInstancesKey];

    final customJobUrl = _getCustomJobUrl(_triggerConfig.sourceUrl);
    var customJobFile;
    try {
      customJobFile =
          await _downloadFile(httpClient, customJobUrl, to: destDir);
    } catch (e) {
      _context.logger.info('No custom job file.');
      customJobFile = null;
    }

    // FIXME: Generate from descriptionFile.
    final packageDescriptionUrl =
        _getPackageDescriptionUrl(_triggerConfig.sourceUrl);
    var packageDescriptionFile;
    try {
      packageDescriptionFile =
          await _downloadFile(httpClient, packageDescriptionUrl, to: destDir);
    } catch (e) {
      _context.logger.info('No package dscription file.');
      packageDescriptionFile = null;
    }

    httpClient.close();

    return new JobDescription(
        jobs,
        Uri.parse(jobDescriptionFile.path),
        customJobFile != null ? Uri.parse(customJobFile.path) : null,
        packageDescriptionFile != null
            ? Uri.parse(packageDescriptionFile.path)
            : null);
  }

  static Uri _getJobDescriptionUrl(Uri baseUrl) {
    // FIXME: Don't hardcode.
    return Uri.parse(baseUrl.toString() + '/beaver/beaver.yaml');
  }

  static Uri _getCustomJobUrl(Uri baseUrl) {
    // FIXME: Don't hardcode.
    return Uri.parse(baseUrl.toString() + '/beaver/beaver.dart');
  }

  static Uri _getPackageDescriptionUrl(Uri baesUrl) {
    // FIXME: Don't hardcode.
    return Uri.parse(baesUrl.toString() + '/../pubspec.yaml');
  }

  static Future<String> _getDestinationDirectory(String id) async {
    final dirPath = path.join(Directory.systemTemp.path, id);
    final dir = new Directory(dirPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dirPath;
  }

  static Future<File> _downloadFile(HttpClient client, Uri url,
      {String to: '.'}) async {
    final file = new File(path.join(to, url.pathSegments.last));

    final request = await client.getUrl(url);
    final response = await request.close();
    await response.pipe(file.openWrite());
    return file;
  }
}

class TaskInstanceRunner {
  final Context _context;
  final String _event;
  final JobDescription _jobDescription;

  TaskInstanceRunner(this._context, this._event, this._jobDescription);

  Future<TaskInstanceResult> run() async {
    _context.logger.fine('JobRunner started.');
    final workingDir = path.dirname(_jobDescription.customJobFile.toFilePath());

    final job = _jobDescription.jobs.firstWhere(
        (YamlMap job) => job['event'] == _event,
        orElse: () => null);
    if (job == null) {
      _context.logger.severe('No job for ${_event} event.');
      throw new Exception('No job for ${_event} event.');
    }

    final dependencyResult = await _getDependencies(workingDir);
    for (final line in dependencyResult.stderr) {
      _context.logger.severe(line);
    }
    for (final line in dependencyResult.stdout) {
      _context.logger.info(line);
    }

    var result;
    if (job['custom']) {
      // We assume there is only one task if custom is true.
      result = await _runCustomJob(workingDir, job['tasks'].first['name']);
    } else {
      result = await _runJob(job['tasks'], job['concurrency'] ?? false,
          _jobDescription.descriptionFile.toFilePath());
    }

    return result;
  }

  static Future<Object> _getDependencies(String workingDir) =>
      runPub(['get'], processWorkingDir: workingDir);

  static Future<TaskInstanceResult> _runCustomJob(
      String workingDir, String taskName) async {
    final result = await Process.run('dart', ['beaver.dart', taskName],
        workingDirectory: workingDir, runInShell: true);

    return new TaskInstanceResult.fromProcessResult(result);
  }

  static Future<TaskInstanceResult> _runJob(Iterable<YamlList> tasks,
      bool concurrency, String jobDescriptionPath) async {
    final taskClassMap = loadClassMapByAnnotation(beaver_core.TaskClass);

    final config = new beaver_core.YamlConfig.fromFile(jobDescriptionPath);
    final logger = new MemoryLogger();
    // FIXME: Pass ContextPart.
    final context = new beaver_core.DefaultContext(config, logger, {});

    final List<beaver_core.Task> taskList = tasks.map((task) {
      final args = task['arguments']
          ? (task['arguments'] as YamlList).toList(growable: false)
          : [];
      return newInstance(taskClassMap[task['name']], args);
    });

    beaver_core.Task task;
    if (concurrency) {
      task = beaver_core.par(taskList);
    } else {
      task = beaver_core.seq(taskList);
    }

    var status = TaskInstanceStatus.success;
    try {
      await task.execute(context);
    } catch (e) {
      logger.error(e);
      status = TaskInstanceStatus.failure;
    }

    return new TaskInstanceResult(status, logger.toString());
  }
}

enum TaskInstanceStatus { success, failure }

class TaskInstanceResult {
  TaskInstanceStatus status;
  String log;

  TaskInstanceResult(this.status, this.log);

  TaskInstanceResult.fromProcessResult(ProcessResult result) {
    status = TaskInstanceStatus.success;
    if (result.exitCode != 0) {
      status = TaskInstanceStatus.failure;
    }

    StringBuffer buffer = new StringBuffer();
    buffer
      ..write('stdout: ')
      ..write(result.stdout)
      ..write(', stderr: ')
      ..write(result.stderr);
    log = buffer.toString();
  }

  @override
  String toString() {
    var statusStr = 'success';
    if (status != TaskInstanceStatus.success) {
      statusStr = 'failure';
    }

    final buffer = new StringBuffer();
    buffer
      ..writeln('JobRunResult: ')
      ..writeln('status: ${statusStr}')
      ..writeln('logs: ${log}');
    return buffer.toString();
  }
}

class MemoryLogger extends beaver_core.Logger {
  final StringBuffer _buffer = new StringBuffer();

  MemoryLogger();

  @override
  void log(beaver_core.LogLevel logLevel, message) {
    _buffer.writeln('${logLevel}: ${message}');
  }

  @override
  String toString() => _buffer.toString();
}