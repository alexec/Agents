package store

import (
	"context"
	"crypto/md5"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"sort"
	"strings"

	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/feature/s3/transfermanager"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	s3types "github.com/aws/aws-sdk-go-v2/service/s3/types"
	"github.com/aws/smithy-go"
	"gocloud.dev/blob"
	"gocloud.dev/blob/s3blob"
	"gocloud.dev/gcerrors"
)

// Blob is the store in a bucket through gocloud.dev/blob (S3Store.swift's job).
//
// What gocloud gives: get, list, delete, and IfNotExist. What it misses, worked round
// here: If-Match (set on the S3 upload input through BeforeWrite's As), the entity tag
// of a write (not returned: taken as the quoted MD5 of the bytes, which is S3's and
// MinIO's tag for a single-part upload without SSE-KMS), and S3's 409
// ConditionalRequestConflict (gcerrors says Unknown: read through As).
type Blob struct {
	b *blob.Bucket
}

func NewBlob(b *blob.Bucket) *Blob { return &Blob{b: b} }

func md5Tag(data []byte) string {
	sum := md5.Sum(data)
	return `"` + hex.EncodeToString(sum[:]) + `"`
}

func (s *Blob) Get(ctx context.Context, key string) (*Object, error) {
	r, err := s.b.NewReader(ctx, key, nil)
	if gcerrors.Code(err) == gcerrors.NotFound {
		return nil, nil
	}
	if err != nil {
		return nil, unavailable("cannot read %s: %v", key, err)
	}
	defer r.Close()
	data, err := io.ReadAll(r)
	if err != nil {
		return nil, unavailable("cannot read %s: %v", key, err)
	}
	tag := md5Tag(data)
	var out s3.GetObjectOutput
	if r.As(&out) && out.ETag != nil {
		tag = *out.ETag
	}
	return &Object{Data: data, ETag: tag}, nil
}

func (s *Blob) Put(ctx context.Context, key string, data []byte, when Condition) (string, error) {
	opts := &blob.WriterOptions{IfNotExist: when.IsAbsent(), ContentType: "application/json"}
	if tag, ok := when.Matching(); ok {
		opts.BeforeWrite = func(as func(any) bool) error {
			var in *transfermanager.UploadObjectInput
			if !as(&in) {
				return fmt.Errorf("this bucket's driver cannot write with If-Match")
			}
			in.IfMatch = aws.String(tag)
			return nil
		}
	}
	err := s.b.WriteAll(ctx, key, data, opts)
	if err != nil {
		if conflict(err, when) {
			return "", &ConflictError{key}
		}
		return "", unavailable("cannot write %s: %v", key, err)
	}
	return md5Tag(data), nil
}

// A refused condition: 412, or 409 when two writes raced, or 404 on an If-Match.
func conflict(err error, when Condition) bool {
	switch gcerrors.Code(err) {
	case gcerrors.FailedPrecondition:
		return true
	case gcerrors.NotFound:
		_, matching := when.Matching()
		return matching
	}
	var api smithy.APIError
	if errors.As(err, &api) {
		switch api.ErrorCode() {
		case "PreconditionFailed", "ConditionalRequestConflict":
			return true
		case "NoSuchKey", "NotFound":
			_, matching := when.Matching()
			return matching
		}
	}
	return false
}

func (s *Blob) Delete(ctx context.Context, key string) error {
	err := s.b.Delete(ctx, key)
	if err != nil && gcerrors.Code(err) != gcerrors.NotFound {
		return unavailable("cannot delete %s: %v", key, err)
	}
	return nil
}

func (s *Blob) List(ctx context.Context, prefix string) ([]Key, error) {
	var out []Key
	it := s.b.List(&blob.ListOptions{Prefix: prefix})
	for {
		obj, err := it.Next(ctx)
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, unavailable("cannot list %s: %v", prefix, err)
		}
		if obj.IsDir {
			continue
		}
		tag := `"` + hex.EncodeToString(obj.MD5) + `"`
		var o s3types.Object
		if obj.As(&o) && o.ETag != nil {
			tag = *o.ETag
		}
		out = append(out, Key{obj.Key, tag})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Key < out[j].Key })
	return out, nil
}

func (s *Blob) Close() error { return s.b.Close() }

// Open reads a store's address: file:///path, or s3://bucket/prefix with
// AGENTS_STORE_ENDPOINT, AGENTS_STORE_PATH_STYLE=1 and the usual AWS keys, as
// StoreAddress.open does.
func Open(ctx context.Context, address string) (Store, error) {
	u, err := url.Parse(address)
	if err != nil {
		return nil, err
	}
	switch u.Scheme {
	case "file":
		return NewFolder(u.Path), nil
	case "s3":
		return OpenS3(ctx, u.Host, strings.Trim(u.Path, "/"), os.Getenv("AGENTS_STORE_ENDPOINT"), os.Getenv("AGENTS_STORE_PATH_STYLE") == "1")
	}
	return nil, fmt.Errorf("%s: a store is file:///path or s3://bucket/prefix", address)
}

// OpenS3 opens bucket (made if absent, for a MinIO walk) under prefix.
func OpenS3(ctx context.Context, bucket, prefix, endpoint string, pathStyle bool) (*Blob, error) {
	region := os.Getenv("AWS_REGION")
	if region == "" {
		region = "us-east-1"
	}
	opts := []func(*awsconfig.LoadOptions) error{awsconfig.WithRegion(region)}
	if id, secret := os.Getenv("AWS_ACCESS_KEY_ID"), os.Getenv("AWS_SECRET_ACCESS_KEY"); id != "" {
		opts = append(opts, awsconfig.WithCredentialsProvider(credentials.NewStaticCredentialsProvider(id, secret, "")))
	}
	cfg, err := awsconfig.LoadDefaultConfig(ctx, opts...)
	if err != nil {
		return nil, err
	}
	client := s3.NewFromConfig(cfg, func(o *s3.Options) {
		if endpoint != "" {
			o.BaseEndpoint = aws.String(endpoint)
		}
		o.UsePathStyle = pathStyle
	})
	if _, err := client.HeadBucket(ctx, &s3.HeadBucketInput{Bucket: aws.String(bucket)}); err != nil {
		if _, err := client.CreateBucket(ctx, &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
			return nil, fmt.Errorf("bucket %s: %w", bucket, err)
		}
	}
	b, err := s3blob.OpenBucket(ctx, client, bucket, nil)
	if err != nil {
		return nil, err
	}
	if prefix != "" {
		b = blob.PrefixedBucket(b, prefix+"/")
	}
	return NewBlob(b), nil
}
