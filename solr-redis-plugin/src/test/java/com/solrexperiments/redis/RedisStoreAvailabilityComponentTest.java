package com.solrexperiments.redis;

import org.apache.solr.common.SolrDocument;
import org.apache.solr.common.SolrDocumentList;
import org.apache.solr.common.params.ModifiableSolrParams;
import org.apache.solr.handler.component.ResponseBuilder;
import org.apache.solr.request.SolrQueryRequest;
import org.apache.solr.response.SolrQueryResponse;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.MockedStatic;
import org.mockito.junit.jupiter.MockitoExtension;
import redis.clients.jedis.Jedis;
import redis.clients.jedis.JedisPool;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
class RedisStoreAvailabilityComponentTest {

    @Mock private ResponseBuilder rb;
    @Mock private SolrQueryRequest req;
    @Mock private SolrQueryResponse rsp;
    @Mock private JedisPool jedisPool;
    @Mock private Jedis jedis;
    @Mock private RedisConnectionManager connectionManager;

    private RedisStoreAvailabilityComponent component;

    @BeforeEach
    void setUp() {
        component = new RedisStoreAvailabilityComponent();
        when(rb.req).thenReturn(req);
        when(rb.rsp).thenReturn(rsp);
        when(jedisPool.getResource()).thenReturn(jedis);
    }

    @Test
    void noStoreIdParam_skipsFiltering() throws Exception {
        ModifiableSolrParams params = new ModifiableSolrParams();
        when(req.getParams()).thenReturn(params);

        component.process(rb);

        verify(rsp, never()).getResults();
    }

    @Test
    void filterMode_removesUnavailableProducts() throws Exception {
        ModifiableSolrParams params = new ModifiableSolrParams();
        params.set(RedisStoreAvailabilityComponent.PARAM_STORE_ID, "store42");
        params.set(RedisStoreAvailabilityComponent.PARAM_PRODUCT_ID_FIELD, "sku");
        params.set(RedisStoreAvailabilityComponent.PARAM_FILTER_MODE, "filter");
        when(req.getParams()).thenReturn(params);

        SolrDocumentList docs = buildDocList(
                doc("1001001"), // available
                doc("2002002"), // unavailable
                doc("3003003")  // available
        );
        when(rsp.getResults()).thenReturn(docs);

        String key = "store:store42:availability";
        when(jedis.getbit(key, 1001001L)).thenReturn(true);
        when(jedis.getbit(key, 2002002L)).thenReturn(false);
        when(jedis.getbit(key, 3003003L)).thenReturn(true);

        try (MockedStatic<RedisConnectionManager> mgr = mockStatic(RedisConnectionManager.class)) {
            mgr.when(RedisConnectionManager::getInstance).thenReturn(connectionManager);
            when(connectionManager.getPool()).thenReturn(jedisPool);

            component.process(rb);
        }

        assertEquals(2, docs.size());
        assertEquals("1001001", docs.get(0).getFieldValue("sku").toString());
        assertEquals("3003003", docs.get(1).getFieldValue("sku").toString());
        assertEquals(2L, docs.getNumFound());
    }

    @Test
    void annotateMode_addsStoreAvailableField() throws Exception {
        ModifiableSolrParams params = new ModifiableSolrParams();
        params.set(RedisStoreAvailabilityComponent.PARAM_STORE_ID, "store99");
        params.set(RedisStoreAvailabilityComponent.PARAM_FILTER_MODE, "annotate");
        when(req.getParams()).thenReturn(params);

        SolrDocument available   = doc("5001001");
        SolrDocument unavailable = doc("5002002");
        SolrDocumentList docs = buildDocList(available, unavailable);
        when(rsp.getResults()).thenReturn(docs);

        String key = "store:store99:availability";
        when(jedis.getbit(key, 5001001L)).thenReturn(true);
        when(jedis.getbit(key, 5002002L)).thenReturn(false);

        try (MockedStatic<RedisConnectionManager> mgr = mockStatic(RedisConnectionManager.class)) {
            mgr.when(RedisConnectionManager::getInstance).thenReturn(connectionManager);
            when(connectionManager.getPool()).thenReturn(jedisPool);

            component.process(rb);
        }

        assertEquals(2, docs.size());
        assertEquals(Boolean.TRUE,  available.getFieldValue("storeAvailable"));
        assertEquals(Boolean.FALSE, unavailable.getFieldValue("storeAvailable"));
    }

    @Test
    void nonNumericSku_treatedAsMissing() throws Exception {
        ModifiableSolrParams params = new ModifiableSolrParams();
        params.set(RedisStoreAvailabilityComponent.PARAM_STORE_ID, "store1");
        when(req.getParams()).thenReturn(params);

        SolrDocument badDoc = new SolrDocument();
        badDoc.addField("sku", "not-a-number");
        SolrDocumentList docs = buildDocList(badDoc);
        when(rsp.getResults()).thenReturn(docs);

        try (MockedStatic<RedisConnectionManager> mgr = mockStatic(RedisConnectionManager.class)) {
            mgr.when(RedisConnectionManager::getInstance).thenReturn(connectionManager);
            when(connectionManager.getPool()).thenReturn(jedisPool);

            component.process(rb);
        }

        // Bad-SKU doc is filtered out
        assertEquals(0, docs.size());
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    private static SolrDocument doc(String sku) {
        SolrDocument d = new SolrDocument();
        d.addField("sku", sku);
        return d;
    }

    private static SolrDocumentList buildDocList(SolrDocument... docs) {
        SolrDocumentList list = new SolrDocumentList();
        for (SolrDocument d : docs) list.add(d);
        list.setNumFound(docs.length);
        return list;
    }
}
