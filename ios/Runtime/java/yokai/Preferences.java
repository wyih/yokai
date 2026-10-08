package yokai;

import android.content.SharedPreferences;
import java.lang.reflect.*;
import java.util.*;
import org.json.*;

final class Preferences implements InvocationHandler {
    private final String name;
    private final Map<String,Object> values = new HashMap<>();
    private final List<SharedPreferences.OnSharedPreferenceChangeListener> listeners = new ArrayList<>();
    private final SharedPreferences proxy;

    Preferences(String name) throws JSONException {
        this.name = name;
        JSONObject stored = new JSONObject(NativeServices.readPreferences(name));
        for (Iterator<String> keys=stored.keys();keys.hasNext();) {
            String key=keys.next(); JSONObject item=stored.getJSONObject(key);
            Object value=item.get("value");
            switch(item.getString("type")) {
                case "long": value=((Number)value).longValue(); break;
                case "int": value=((Number)value).intValue(); break;
                case "float": value=((Number)value).floatValue(); break;
                case "set":
                    Set<String> set=new HashSet<>();JSONArray a=(JSONArray)value;
                    for(int i=0;i<a.length();i++)set.add(a.getString(i));value=set;break;
            }
            values.put(key,value);
        }
        proxy=(SharedPreferences)Proxy.newProxyInstance(getClass().getClassLoader(),new Class[]{SharedPreferences.class},this);
    }
    SharedPreferences get(){return proxy;}
    private Object identity(Object p,String action,Object[] args){return action.equals("toString")?"iOS SharedPreferences("+name+")":action.equals("hashCode")?System.identityHashCode(p):p==args[0];}
    public synchronized Object invoke(Object p,Method method,Object[] args) throws Exception {
        String action=method.getName();
        if(action.equals("toString")||action.equals("hashCode")||action.equals("equals"))return identity(p,action,args);
        if(action.equals("edit"))return Proxy.newProxyInstance(getClass().getClassLoader(),new Class[]{SharedPreferences.Editor.class},new Editor());
        if(action.equals("getAll"))return new HashMap<>(values);
        if(action.equals("contains"))return values.containsKey(args[0]);
        if(action.startsWith("get")){Object v=values.getOrDefault(args[0],args[1]);return v instanceof Set?new HashSet<>((Set<?>)v):v;}
        if(action.equals("registerOnSharedPreferenceChangeListener")){listeners.add((SharedPreferences.OnSharedPreferenceChangeListener)args[0]);return null;}
        if(action.equals("unregisterOnSharedPreferenceChangeListener")){listeners.remove(args[0]);return null;}
        throw new UnsupportedOperationException("SharedPreferences."+action);
    }
    private final class Editor implements InvocationHandler {
        private final Map<String,Object> pending=new HashMap<>();
        private boolean clear;
        public Object invoke(Object p,Method method,Object[] args)throws Exception {
            synchronized(Preferences.this){
                String action=method.getName();
                if(action.equals("toString")||action.equals("hashCode")||action.equals("equals"))return identity(p,action,args);
                if(action.startsWith("put")){pending.put((String)args[0],args[1] instanceof Set?new HashSet<>((Set<?>)args[1]):args[1]);return p;}
                if(action.equals("remove")){pending.put((String)args[0],null);return p;}
                if(action.equals("clear")){clear=true;return p;}
                if(action.equals("commit")||action.equals("apply")){
                    Set<String> changed=new HashSet<>(pending.keySet());Map<String,Object> next=new HashMap<>(values);
                    if(clear){changed.addAll(values.keySet());next.clear();}
                    for(var item:pending.entrySet()){if(item.getValue()==null)next.remove(item.getKey());else next.put(item.getKey(),item.getValue());}
                    JSONObject json=new JSONObject();
                    for(var item:next.entrySet()){
                        Object v=item.getValue();String type=v instanceof Long?"long":v instanceof Integer?"int":v instanceof Float?"float":v instanceof Set?"set":v instanceof Boolean?"boolean":"string";
                        json.put(item.getKey(),new JSONObject().put("type",type).put("value",v instanceof Set?new JSONArray((Set<?>)v):v));
                    }
                    NativeServices.writePreferences(name,json.toString());values.clear();values.putAll(next);pending.clear();clear=false;
                    for(var listener:new ArrayList<>(listeners))for(String key:changed)listener.onSharedPreferenceChanged(proxy,key);
                    return action.equals("commit")?Boolean.TRUE:null;
                }
                throw new UnsupportedOperationException("SharedPreferences.Editor."+action);
            }
        }
    }
}
