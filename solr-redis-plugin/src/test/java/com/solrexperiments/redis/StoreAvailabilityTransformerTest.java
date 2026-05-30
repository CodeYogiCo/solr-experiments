package com.solrexperiments.redis;

import org.apache.lucene.document.Document;
import org.apache.lucene.document.NumericDocValuesField;
import org.apache.lucene.document.StringField;
import org.apache.lucene.document.Field;
import org.apache.lucene.index.DirectoryReader;
import org.apache.lucene.index.IndexWriter;
import org.apache.lucene.index.IndexWriterConfig;
import org.apache.lucene.store.ByteBuffersDirectory;
import org.apache.lucene.store.Directory;
import org.apache.solr.common.SolrDocument;
import org.apache.solr.common.SolrException;
import org.apache.solr.common.params.ModifiableSolrParams;
import org.apache.solr.response.ResultContext;
import org.apache.solr.response.transform.DocTransformer;
import org.apache.solr.search.SolrIndexSearcher;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.MockedStatic;
import org.mockito.junit.jupiter.MockitoExtension;
import redis.clients.jedis.Jedis;
import redis.clients.jedis.JedisPool;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

/**
 * Unit tests for the annotate path ({@link StoreAvailabilityTransformerFactory}).
 *
 * <p>The transformer reads the SKU from <b>DocValues</b> using the Lucene docid
 * (reading the {@link SolrDocument}'s stored fields inside a transformer returns
 * the wrong, previously-streamed doc's value). These tests therefore build a
 * tiny in-memory Lucene index with a {@code sku} {@link NumericDocValuesField}
 * and exercise the real lookup; only the Redis call itself is mocked.
 */
@ExtendWith(MockitoExtension.class)
class StoreAvailabilityTransformerTest {

    @Mock private JedisPool jedisPool;
    @Mock private Jedis jedis;
    @Mock private RedisConnectionManager connectionManager;

    private Directory dir;
    private DirectoryReader reader;

    @AfterEach
    void tearDown() throws Exception {
        if (reader != null) reader.close();
        if (dir != null) dir.close();
    }

    /**
     * Build a one-segment index. Each entry is either a SKU value (a sku
     * NumericDocValuesField is added) or {@code null} (no DocValues for that doc).
     * Doc ids are assigned in insertion order.
     */
    private void buildIndex(Long... skusByDoc) throws Exception {
        dir = new ByteBuffersDirectory();
        try (IndexWriter w = new IndexWriter(dir, new IndexWriterConfig())) {
            for (Long sku : skusByDoc) {
                Document d = new Document();
                d.add(new StringField("id", "doc", Field.Store.YES));
                if (sku != null) {
                    d.add(new NumericDocValuesField("sku", sku));
                }
                w.addDocument(d);
            }
            w.forceMerge(1);
        }
        reader = DirectoryReader.open(dir);
    }

    private DocTransformer newTransformer(String storeId) {
        ModifiableSolrParams params = new ModifiableSolrParams();
        params.set(StoreAvailabilityTransformerFactory.PARAM_STORE_ID, storeId);
        DocTransformer t = new StoreAvailabilityTransformerFactory()
                .create("storeAvailable", params, null);

        // Hand the transformer the index's reader context (the only thing it
        // pulls off the searcher), mocking SolrIndexSearcher for that one call.
        SolrIndexSearcher searcher = mock(SolrIndexSearcher.class);
        when(searcher.getTopReaderContext()).thenReturn(reader.getContext());
        ResultContext ctx = mock(ResultContext.class);
        when(ctx.getSearcher()).thenReturn(searcher);
        t.setContext(ctx);
        return t;
    }

    @Test
    void missingStoreId_throwsBadRequest() {
        ModifiableSolrParams params = new ModifiableSolrParams();
        StoreAvailabilityTransformerFactory factory = new StoreAvailabilityTransformerFactory();
        SolrException ex = assertThrows(SolrException.class,
                () -> factory.create("storeAvailable", params, null));
        assertEquals(SolrException.ErrorCode.BAD_REQUEST.code, ex.code());
    }

    @Test
    void annotatesAvailableTrue() throws Exception {
        buildIndex(1001001L);
        SolrDocument doc = new SolrDocument();

        when(jedisPool.getResource()).thenReturn(jedis);
        when(jedis.getbit("store:store42:availability", 1001001L)).thenReturn(true);

        try (MockedStatic<RedisConnectionManager> mgr = mockStatic(RedisConnectionManager.class)) {
            mgr.when(RedisConnectionManager::getInstance).thenReturn(connectionManager);
            when(connectionManager.getPool()).thenReturn(jedisPool);

            newTransformer("store42").transform(doc, 0);
        }

        assertEquals(Boolean.TRUE, doc.getFieldValue("storeAvailable"));
    }

    @Test
    void annotatesAvailableFalse() throws Exception {
        buildIndex(1001001L, 2002002L);
        SolrDocument doc = new SolrDocument();

        when(jedisPool.getResource()).thenReturn(jedis);
        when(jedis.getbit("store:store42:availability", 2002002L)).thenReturn(false);

        try (MockedStatic<RedisConnectionManager> mgr = mockStatic(RedisConnectionManager.class)) {
            mgr.when(RedisConnectionManager::getInstance).thenReturn(connectionManager);
            when(connectionManager.getPool()).thenReturn(jedisPool);

            // docid 1 -> sku 2002002 (proves we resolve the SKU per docid, not
            // off the SolrDocument).
            newTransformer("store42").transform(doc, 1);
        }

        assertEquals(Boolean.FALSE, doc.getFieldValue("storeAvailable"));
    }

    @Test
    void missingSkuDocValues_annotatedUnavailable_withoutRedisCall() throws Exception {
        buildIndex((Long) null);   // doc 0 has no sku DocValues
        SolrDocument doc = new SolrDocument();

        try (MockedStatic<RedisConnectionManager> mgr = mockStatic(RedisConnectionManager.class)) {
            newTransformer("store42").transform(doc, 0);
            // No SKU -> short-circuits before ever touching Redis.
            mgr.verifyNoInteractions();
        }

        assertEquals(Boolean.FALSE, doc.getFieldValue("storeAvailable"));
    }

    @Test
    void transformerName_isTheRequestedField() throws Exception {
        buildIndex(1001001L);
        assertEquals("storeAvailable", newTransformer("store42").getName());
    }
}
