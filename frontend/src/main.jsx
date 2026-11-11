import React, { useEffect, useMemo, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import './styles.css';
import { fetchJson, rememberedJob } from './api';

const API_BASE = import.meta.env.VITE_API_BASE ?? '';

const formatBytes = (bytes) => {
  if (!bytes && bytes !== 0) return '-';
  const units = ['B', 'KB', 'MB', 'GB'];
  let value = bytes;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return `${value.toFixed(value >= 10 || unit === 0 ? 0 : 1)} ${units[unit]}`;
};

const fullUrl = (path) => `${API_BASE}${path}`;

function App() {
  const [files, setFiles] = useState([]);
  const [isDragging, setIsDragging] = useState(false);
  const [job, setJob] = useState(null);
  const [restoring, setRestoring] = useState(true);
  const [submitting, setSubmitting] = useState(false);
  const submittingRef = useRef(false);
  const [message, setMessage] = useState('');
  const [apiStatus, setApiStatus] = useState('checking');
  const [settings, setSettings] = useState({
    maxWidth: 1800,
    maxHeight: 1800,
    format: 'keep',
    quality: 82,
  });

  const totalOriginal = useMemo(() => {
    const source = job?.files?.length ? job.files.map((file) => file.original_size) : files.map((file) => file.size);
    return source.reduce((sum, size) => sum + (size || 0), 0);
  }, [files, job]);

  const totalOutput = useMemo(() => {
    return job?.files?.reduce((sum, file) => sum + (file.output_size || 0), 0) ?? 0;
  }, [job]);

  const doneCount = job?.files?.filter((file) => file.status === 'done').length ?? 0;
  const failedCount = job?.files?.filter((file) => file.status === 'failed').length ?? 0;
  const busy = restoring || submitting || (job && !['done', 'failed'].includes(job.status));
  const canSubmit = files.length > 0 && !busy;

  useEffect(() => {
    fetchJson(fullUrl('/api/health'))
      .then((health) => setApiStatus(health.native_optimizer ? 'ready' : 'native missing'))
      .catch(() => setApiStatus('api unavailable'));
  }, []);

  useEffect(() => {
    if (!job || ['done', 'failed'].includes(job.status)) return undefined;

    let cancelled = false;
    let timer;
    const controller = new AbortController();
    const poll = async () => {
      try {
        const updated = await fetchJson(fullUrl(`/api/jobs/${job.id}`), { signal: controller.signal });
        if (!cancelled) {
          setJob(updated);
          setMessage('');
          if (!['done', 'failed'].includes(updated.status)) timer = window.setTimeout(poll, 900);
        }
      } catch (error) {
        if (!cancelled) {
          if (error.status === 404) {
            rememberedJob.clear();
            setJob(null);
            setMessage('This job no longer exists. Select images to start again.');
            return;
          }
          setMessage('Job tracking interrupted. Retrying…');
          timer = window.setTimeout(poll, 2000);
        }
      }
    };
    timer = window.setTimeout(poll, 900);
    return () => { cancelled = true; controller.abort(); window.clearTimeout(timer); };
  }, [job?.id, job?.status]);

  useEffect(() => {
    if (job) rememberedJob.set(job.id);
  }, [job?.id]);

  useEffect(() => {
    const id = rememberedJob.get();
    if (!id) { setRestoring(false); return; }
    fetchJson(fullUrl(`/api/jobs/${encodeURIComponent(id)}`))
      .then(setJob)
      .catch((error) => {
        if (error.status === 404) rememberedJob.clear();
        setMessage(error.status === 404 ? 'Previous job no longer exists.' : 'Previous job could not be restored. Reload to retry.');
      })
      .finally(() => setRestoring(false));
  }, []);

  const addFiles = (incoming) => {
    if (busy || submittingRef.current) return;
    const imageFiles = Array.from(incoming).filter((file) => /\.(jpe?g|png|bmp|tiff?)$/i.test(file.name));
    rememberedJob.clear();
    setFiles((current) => job ? imageFiles : [...current, ...imageFiles]);
    setJob(null);
    setMessage(imageFiles.length === incoming.length ? '' : 'Only JPEG, PNG, BMP, and TIFF are supported.');
  };

  const submit = async () => {
    if (!canSubmit || submittingRef.current) return;
    submittingRef.current = true;
    setSubmitting(true);
    setMessage('');
    const form = new FormData();
    files.forEach((file) => form.append('images[]', file));
    form.append('max_width', settings.maxWidth);
    form.append('max_height', settings.maxHeight);
    form.append('format', settings.format);
    form.append('quality', settings.quality);

    try {
      const body = await fetchJson(fullUrl('/api/jobs'), {
        method: 'POST',
        body: form,
      });
      setJob(body);
    } catch (error) {
      setMessage(error.name === 'AbortError' ? 'The API request timed out. Check job tracking before retrying.' : error.message || 'The Ruby API is not reachable.');
    } finally {
      submittingRef.current = false;
      setSubmitting(false);
    }
  };

  return (
    <main>
      <header className="topbar">
        <div>
          <p className="eyebrow">Ruby + C++ + React</p>
          <h1>Local Image Optimizer</h1>
        </div>
        <div className="statusGroup">
          <div className="statusPill">{job ? job.status : 'ready'}</div>
          <div className="statusPill muted">{apiStatus}</div>
        </div>
      </header>

      <section className="workspace">
        <aside className="controls" aria-label="Optimization controls">
          <Dropzone
            files={files}
            isDragging={isDragging}
            setIsDragging={setIsDragging}
            addFiles={addFiles}
            disabled={busy}
          />

          <div className="panel">
            <h2>Output</h2>
            <label>
              Size preset
              <button type="button" className="secondary" onClick={() => setSettings({ ...settings, maxWidth: 1800, maxHeight: 1800 })}>
                Apply 1800 × 1800 maximum
              </button>
            </label>
            <label>
              Format
              <select value={settings.format} onChange={(event) => setSettings({ ...settings, format: event.target.value })}>
                <option value="keep">Keep source</option>
                <option value="jpeg">JPEG</option>
                <option value="png">PNG</option>
                <option value="bmp">BMP</option>
                <option value="tiff">TIFF</option>
              </select>
            </label>
            <label>
              Quality
              <input
                type="range"
                min="1"
                max="100"
                value={settings.quality}
                onChange={(event) => setSettings({ ...settings, quality: Number(event.target.value) })}
              />
              <span className="rangeValue">{settings.quality} / 100</span>
              <small>JPEG visual quality; TIFF compression effort. PNG and BMP ignore quality.</small>
            </label>
            <div className="sizeGrid">
              <label>
                Max width
                <input
                  type="number"
                  min="1"
                  value={settings.maxWidth}
                  onChange={(event) => setSettings({ ...settings, maxWidth: Number(event.target.value) })}
                />
              </label>
              <label>
                Max height
                <input
                  type="number"
                  min="1"
                  value={settings.maxHeight}
                  onChange={(event) => setSettings({ ...settings, maxHeight: Number(event.target.value) })}
                />
              </label>
            </div>
            <button className="primary" type="button" disabled={!canSubmit} onClick={submit}>
              {submitting ? 'Uploading…' : 'Optimize batch'}
            </button>
            {job && ['done', 'failed'].includes(job.status) && doneCount > 0 && (
              <a className="secondary" href={fullUrl(`/api/jobs/${job.id}/export`)}>
                Download zip
              </a>
            )}
            {job && <p aria-live="polite">{doneCount + failedCount} / {job.files.length} processed</p>}
            {job?.errors?.map((error, index) => <p className="error" key={index}>{error}</p>)}
            {message && <p className="message">{message}</p>}
          </div>

          <Stats
            files={job?.files?.length ?? files.length}
            done={doneCount}
            failed={failedCount}
            savingsOriginal={job?.files?.filter((file) => file.status === 'done').reduce((sum, file) => sum + file.original_size, 0) ?? 0}
            totalOriginal={totalOriginal}
            totalOutput={totalOutput}
          />
        </aside>

        <section className="results" aria-label="Optimization results">
          {job?.files?.length ? (
            job.files.map((file) => <ResultRow key={file.id} jobId={job.id} file={file} />)
          ) : (
            <EmptyState files={files} removeFile={(index) => setFiles((current) => current.filter((_, i) => i !== index))} />
          )}
        </section>
      </section>
    </main>
  );
}

function Dropzone({ files, isDragging, setIsDragging, addFiles, disabled }) {
  const inputRef = useRef(null);

  return (
    <div
      className={`dropzone ${isDragging ? 'dragging' : ''}`}
      onDragOver={(event) => {
        event.preventDefault();
        setIsDragging(true);
      }}
      onDragLeave={() => setIsDragging(false)}
      onDrop={(event) => {
        event.preventDefault();
        setIsDragging(false);
        addFiles(event.dataTransfer.files);
      }}
    >
      <input
        ref={inputRef}
        type="file"
        accept="image/jpeg,image/png,image/bmp,image/tiff,.jpg,.jpeg,.png,.bmp,.tif,.tiff"
        multiple
        disabled={disabled}
        hidden
        onChange={(event) => { addFiles(event.target.files); event.target.value = ''; }}
      />
      <button className="dropButton" disabled={disabled} type="button" onClick={() => inputRef.current?.click()}>
        Choose images
      </button>
      <p>{files.length ? `${files.length} image${files.length === 1 ? '' : 's'} staged` : 'Drag images here for local processing'}</p>
    </div>
  );
}

function Stats({ files, done, failed, savingsOriginal, totalOriginal, totalOutput }) {
  const savings = savingsOriginal ? Math.round((1 - totalOutput / savingsOriginal) * 100) : 0;
  return (
    <div className="stats">
      <div>
        <strong>{files}</strong>
        <span>Files</span>
      </div>
      <div>
        <strong>{done}</strong>
        <span>Done</span>
      </div>
      <div>
        <strong>{failed}</strong>
        <span>Failed</span>
      </div>
      <div>
        <strong>{savings}%</strong>
        <span>Saved</span>
      </div>
      <p>{formatBytes(totalOriginal)} original / {totalOutput ? formatBytes(totalOutput) : '-' } optimized</p>
    </div>
  );
}

function EmptyState({ files, removeFile }) {
  if (!files.length) {
    return (
      <div className="empty">
        <h2>No images yet</h2>
        <p>Stage a batch to see previews, compression totals, dimensions, and download links.</p>
      </div>
    );
  }

  return (
    <div className="fileList">
      {files.map((file, index) => (
        <div className="fileChip" key={`${file.name}-${file.lastModified}-${index}`}>
          <span>{file.name}</span>
          <small>{formatBytes(file.size)}</small>
          <button type="button" onClick={() => removeFile(index)} aria-label={`Remove ${file.name}`}>
            Remove
          </button>
        </div>
      ))}
    </div>
  );
}

function ResultRow({ jobId, file }) {
  const metadata = file.metadata ?? {};
  const percent = file.original_size && file.output_size
    ? Math.round((1 - file.output_size / file.original_size) * 100)
    : 0;

  return (
    <article className="result">
      <div className="resultHeader">
        <div>
          <h2>{file.name}</h2>
          <p>{file.status === 'done' ? `${metadata.width} x ${metadata.height} ${metadata.format?.toUpperCase()}` : file.status}</p>
        </div>
        <span className={`badge ${file.status}`}>{file.status}</span>
      </div>

      {file.status === 'done' && (
        <>
          <Compare
            original={fullUrl(`/api/files/${jobId}/original/${encodeURIComponent(file.name)}`)}
            optimized={fullUrl(`/api/files/${jobId}/optimized/${encodeURIComponent(file.output_name)}`)}
          />
          <div className="metrics">
            <span>Before {formatBytes(file.original_size)}</span>
            <span>After {formatBytes(file.output_size)}</span>
            <span>{percent}% saved</span>
            <a href={fullUrl(`/api/files/${jobId}/optimized/${encodeURIComponent(file.output_name)}?download=1`)} download>
              Download
            </a>
          </div>
        </>
      )}

      {file.status === 'failed' && <p className="error">{file.error}</p>}
    </article>
  );
}

function Compare({ original, optimized }) {
  const [split, setSplit] = useState(50);
  const [previewFailed, setPreviewFailed] = useState(false);
  if (previewFailed) return <p className="metrics">This browser cannot preview this format. Download the file to inspect it.</p>;

  return (
    <div className="compare" style={{ '--split': `${split}%` }}>
      <img className="optimizedImage" src={optimized} onError={() => setPreviewFailed(true)} alt="Optimized" />
      <img className="originalImage" src={original} onError={() => setPreviewFailed(true)} alt="Original" />
      <div className="divider" style={{ left: `${split}%` }} />
      <input
        className="splitSlider"
        aria-label="Compare original and optimized image"
        type="range"
        min="0"
        max="100"
        value={split}
        onChange={(event) => setSplit(Number(event.target.value))}
      />
      <span className="label left">Original</span>
      <span className="label right">Optimized</span>
    </div>
  );
}

createRoot(document.getElementById('root')).render(<App />);
